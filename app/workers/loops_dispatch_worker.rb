require "digest"
require "securerandom"
require_relative "../lib/email_normalizer"

class LoopsDispatchWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default

  # Redis semaphore for limiting concurrent jobs
  SEMAPHORE_KEY = "loops_dispatch:semaphore"
  MAX_CONCURRENT = 10  # Matches LoopsService.rate_limit_rps
  SEMAPHORE_TTL = 3600  # 1 hour safety net for crashed jobs

  # Advisory lock namespace for per-email locking (same as PrepareLoopsFieldsForOutboxJob)
  ADVISORY_LOCK_NAMESPACE = 0x504C4600  # ASCII: "PLF" (PrepareLoopsFields)

  BATCH_SIZE = 50  # Process up to 50 emails per run

  def perform
    # Acquire semaphore slot - skip if at limit
    unless acquire_semaphore
      Rails.logger.debug("LoopsDispatchWorker: Skipping - at concurrency limit (#{self.class.semaphore_count}/#{MAX_CONCURRENT})")
      return 0
    end

    begin
      # Batch envelopes by email using FOR UPDATE SKIP LOCKED for concurrent workers
      processed_count = 0

      loop do
        # Get a batch of queued envelopes (skip locked to allow concurrent workers)
        # Lock the envelopes themselves, then group by email
        envelopes = LoopsOutboxEnvelope.queued
                                       .order(:created_at)
                                       .limit(BATCH_SIZE)
                                       .lock("FOR UPDATE SKIP LOCKED")
                                       .to_a

        break if envelopes.empty?

        # Group by email and process each email
        envelopes_by_email = envelopes.group_by(&:email_normalized)

        envelopes_by_email.each do |email_normalized, email_envelopes|
          process_email(email_normalized)
          processed_count += 1
        end
      end

      processed_count
    ensure
      # Always release semaphore, even if job crashes
      release_semaphore
    end
  end

  # Redis semaphore methods for limiting concurrent execution

  # Get the current number of concurrent LoopsDispatchWorker jobs
  def self.semaphore_count
    redis = REDIS_FOR_RATE_LIMITING
    redis.scard(SEMAPHORE_KEY).to_i
  rescue => e
    Rails.logger.warn("LoopsDispatchWorker: Failed to check semaphore count: #{e.message}")
    0
  end

  # Try to acquire a semaphore slot (returns true if acquired, false if at limit)
  # Public so tests can access it
  def acquire_semaphore
    redis = REDIS_FOR_RATE_LIMITING
    jid = @jid || self.jid || SecureRandom.hex(12)
    self.semaphore_jid = jid  # Store for release

    # Use Lua script for atomic check-and-add
    # This ensures we don't exceed MAX_CONCURRENT even with concurrent requests
    script = <<~LUA
      local key = KEYS[1]
      local jid = ARGV[1]
      local max_concurrent = tonumber(ARGV[2])
      local ttl = tonumber(ARGV[3])

      local count = redis.call('SCARD', key)

      if count < max_concurrent then
        redis.call('SADD', key, jid)
        redis.call('EXPIRE', key, ttl)
        return 1
      else
        return 0
      end
    LUA

    result = redis.eval(script, keys: [ SEMAPHORE_KEY ], argv: [ jid, MAX_CONCURRENT.to_s, SEMAPHORE_TTL.to_s ])
    result == 1
  rescue => e
    Rails.logger.warn("LoopsDispatchWorker: Failed to acquire semaphore: #{e.message}")
    false
  end

  # Release semaphore slot
  # Public so tests can access it
  def release_semaphore
    redis = REDIS_FOR_RATE_LIMITING
    jid = semaphore_jid || @jid || self.jid || SecureRandom.hex(12)
    redis.srem(SEMAPHORE_KEY, jid)
  rescue => e
    Rails.logger.warn("LoopsDispatchWorker: Failed to release semaphore: #{e.message}")
  end

  private

  # Store the jid used for semaphore (set during acquire, used during release)
  attr_accessor :semaphore_jid

  def process_email(email_normalized)
    # Acquire per-email advisory lock
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      lock_key = email_to_lock_key(email_normalized)
      result = connection.execute(
        "SELECT pg_try_advisory_lock(#{lock_key})"
      )

      lock_acquired = result.first["pg_try_advisory_lock"]
      unless lock_acquired
        Rails.logger.debug("LoopsDispatchWorker: Skipping #{email_normalized} - already processing")
        return
      end

      begin
        # Load all queued envelopes for this email
        envelopes = LoopsOutboxEnvelope.queued
                                       .for_email(email_normalized)
                                       .order(:created_at)
                                       .to_a

        return if envelopes.empty?

        # Determine sync_source for this email batch
        sync_source = envelopes.first&.sync_source || SyncSource.find_by(id: envelopes.first&.provenance&.dig("sync_source_id"))

        # Preflight: check if contact exists and load baselines if needed
        # This can raise LoopsService::ApiError if email is invalid
        begin
        contact_exists = sync_source ? LoopsFieldBaseline.check_contact_existence_and_load_baselines(email_normalized: email_normalized) : true
        rescue LoopsService::ApiError => e
          # Mark envelopes as failed if preflight check fails (e.g., invalid email)
          Rails.logger.error("LoopsDispatchWorker: Preflight check failed for #{email_normalized}: #{e.class} - #{e.message}")
          ApplicationRecord.transaction do
            envelopes.each do |envelope|
              envelope.update_columns(
                status: :failed,
                error: {
                  message: e.message,
                  class: e.class.name,
                  stage: "preflight_check",
                  occurred_at: Time.current.iso8601
                },
                updated_at: Time.current
              )
            end
          end
          if e.status_code.between?(400, 499)
            Rails.logger.warn("LoopsDispatchWorker: Permanent preflight error (HTTP #{e.status_code}) for #{email_normalized}, not retrying: #{e.message}")
            return
          end

          raise
        end

        # Merge envelopes: combine payloads, latest modified_at wins per field
        merged_payload = merge_envelopes(envelopes)

        # Process mailing lists: idempotence, default list, catalog sync, validation
        process_mailing_lists(merged_payload, email_normalized, sync_source, contact_exists, envelopes)

        # Filter by loops_field_baselines AFTER merging
        filtered_payload = filter_by_baselines(email_normalized, merged_payload)

        if filtered_payload.empty?
          # Nothing to send - mark all as ignored_noop
          envelopes.each { |e| e.update!(status: :ignored_noop) }
          return
        end

        # Apply strategies and prepare payload for Loops API
        loops_payload = apply_strategies(filtered_payload)

        if loops_payload.empty?
          # All fields filtered out by strategy (:upsert skipping nil values)
          envelopes.each { |e| e.update!(status: :ignored_noop) }
          return
        end

        # Call LoopsService.update_contact (rate limiting handled internally)
        # All payload data is stored in DB: envelope.payload (what was queued),
        # audit records (what was sent + response), and baselines (what was persisted)
        request_id = nil
        response = nil

        begin
          response = LoopsService.update_contact(email: email_normalized, **loops_payload)

          # Fix response parsing: Loops API returns {"success"=>true, "id"=>"..."}
          # Use "id" as request_id if present, otherwise generate UUID
          request_id = response&.dig("id") || response&.dig("request_id") || SecureRandom.uuid

          # Validate that the update actually succeeded
          # Loops API returns {"success"=>true, "id"=>"..."} on success
          unless response && response["success"] == true
            error_msg = "Loops API update did not succeed. Response: #{response.inspect}"
            Rails.logger.error("LoopsDispatchWorker: #{error_msg}")

            # Wrap envelope updates in a transaction to ensure they're committed
            # Use update_columns to bypass validations and ensure persistence
            ApplicationRecord.transaction do
            envelopes.each do |envelope|
                envelope.update_columns(
                status: :failed,
                error: {
                  message: error_msg,
                  response: response,
                  loops_payload_sent: loops_payload,  # Store what was actually sent
                  occurred_at: Time.current.iso8601
                  },
                  updated_at: Time.current
              )
              end
            end
            # Raise exception after ensuring envelopes are marked as failed
            raise StandardError.new(error_msg)
          end
        rescue => e
          # Mark envelopes as failed and store full error details in DB for debugging
          Rails.logger.error("LoopsDispatchWorker: Error updating Loops contact: #{e.class} - #{e.message}")
          Rails.logger.error("LoopsDispatchWorker: Error backtrace: #{e.backtrace.first(5).join("\n")}")

          # Mark envelopes as failed and store full error details in DB for debugging
          error_hash = {
            message: e.message,
            class: e.class.name,
            loops_payload_sent: loops_payload,  # Store what was actually sent
            backtrace: e.backtrace.first(10),  # Store backtrace for debugging
            occurred_at: Time.current.iso8601
          }
          # Include response if available (e.g., when error comes from unsuccessful API response)
          error_hash[:response] = response if defined?(response) && response

          ApplicationRecord.transaction do
            envelopes.each do |envelope|
              envelope.update_columns(
                status: :failed,
                error: error_hash,
                updated_at: Time.current
              )
            end
          end

          # Don't retry permanent API errors (4xx) — the data is wrong and retrying won't fix it
          # 429 rate limits are already handled internally by LoopsService
          if e.is_a?(LoopsService::ApiError) && e.status_code.between?(400, 499)
            Rails.logger.warn("LoopsDispatchWorker: Permanent API error (HTTP #{e.status_code}) for #{email_normalized}, not retrying: #{e.message}")
            return
          end

          raise
        end

        # In DB transaction: update baselines, create audit records, mark envelopes
        ApplicationRecord.transaction do
          sent_fields = Set.new
          filtered_fields = Set.new

          filtered_payload.each do |field_name, field_data|
            # Skip mailingLists - we handle it separately with individual entries per list subscription
            next if field_name == "mailingLists" || field_name == :mailingLists

            if loops_payload.key?(field_name)
              sent_fields << field_name

              # Find or create baseline and capture old value BEFORE updating
              baseline = LoopsFieldBaseline.find_or_create_baseline(
                email_normalized: email_normalized,
                field_name: field_name
              )
              former_loops_value = baseline.last_sent_value

              # Extract value from field_data (handle both string and symbol keys)
              field_data_hash = field_data.is_a?(Hash) ? field_data : {}
              value_to_send = loops_payload[field_name]  # Use the value that was actually sent to Loops

              # Validate that the API call succeeded before updating baseline
              # This ensures baseline only reflects values that were actually persisted in Loops
              if response && response["success"] == true
                # Update baseline only after confirming successful API update
                baseline.update_sent_value(
                  value: value_to_send,
                  expires_in_days: 90
                )
              else
                Rails.logger.error("LoopsDispatchWorker: NOT updating baseline for #{field_name} - API call did not succeed")
                # Don't update baseline if API call failed
              end

              # Create audit record
              # Find provenance from first envelope (they should all have same provenance per email)
              provenance = envelopes.first.provenance

              # Extract field provenance - match by field name
              field_provenance = provenance["fields"]&.find { |f|
                # Match by field name - map back from loops_field_name to sync source field
                sync_source_field_name = f["sync_source_field_name"]
                sync_source_field_name&.sub(/\ALoops\s*-\s*/i, "") == field_name ||
                field_name == sync_source_field_name
              }

              # Build sync-source-agnostic provenance metadata for audit record
              # This stores sync-source-specific identifiers from the envelope provenance
              audit_provenance = {}

              # Store sync-source-agnostic identifiers
              audit_provenance["sync_source_type"] = provenance["sync_source_type"]

              # Add sync-source-specific metadata if present
              # Metadata comes from sync_source.metadata and includes source_id
              if provenance["sync_source_metadata"]
                # Store the sync-source-specific metadata generically
                # Each sync source type can structure this differently
                audit_provenance["sync_source_metadata"] = provenance["sync_source_metadata"]
              end

              # Create audit record only if API call succeeded
              # Store all debugging data: old/new values, request_id, provenance, response, and payload sent
              if response && response["success"] == true
                # Store response and full payload sent in provenance for debugging
                audit_provenance_with_response = audit_provenance.dup
                audit_provenance_with_response["loops_api_response"] = response
                audit_provenance_with_response["loops_payload_sent"] = loops_payload  # Store full payload that was sent

                LoopsContactChangeAudit.create!(
                  occurred_at: Time.current,
                  email_normalized: email_normalized,
                  field_name: field_name,
                  former_loops_value: former_loops_value,
                  new_loops_value: value_to_send,  # Use the value that was actually sent
                  former_sync_source_value: field_provenance&.dig("former_sync_source_value"),
                  new_sync_source_value: field_provenance&.dig("new_sync_source_value"),
                  strategy: (field_data_hash[:strategy] || field_data_hash["strategy"] || :upsert).to_s,
                  sync_source_id: provenance["sync_source_id"],
                  sync_source_table_id: provenance["sync_source_table_id"],
                  sync_source_record_id: provenance["sync_source_record_id"],
                  sync_source_field_id: field_provenance&.dig("sync_source_field_id"),
                  provenance: audit_provenance_with_response,
                  request_id: request_id
                )
              else
                Rails.logger.warn("LoopsDispatchWorker: NOT creating audit record for #{field_name} - API call did not succeed")
              end
            else
              filtered_fields << field_name
            end
          end

          # Handle mailing lists separately: create subscription records and audit entries
          if response && response["success"] == true && loops_payload.key?("mailingLists")
            # Add mailingLists to sent_fields since it was successfully sent
            sent_fields << "mailingLists"

            mailing_lists_value = loops_payload["mailingLists"]
            if mailing_lists_value.is_a?(Hash)
              now = Time.current
              provenance = envelopes.first.provenance

              mailing_lists_value.each do |list_id, subscribed|
                next unless subscribed == true

                # Create subscription record
                begin
                  subscription = LoopsListSubscription.create!(
                    email_normalized: email_normalized,
                    list_id: list_id
                    # subscribed_at is automatically set by database default
                  )

                  # Find list catalog entry for friendly name
                  loops_list = LoopsList.find_by(loops_list_id: list_id)

                  # Create audit record
                  audit_provenance = {
                    "sync_source_type" => provenance["sync_source_type"],
                    "list" => {
                      "id" => list_id,
                      "name" => loops_list&.name,
                      "is_public" => loops_list&.is_public
                    },
                    "loops_api_response" => response,
                    "loops_payload_sent" => { "mailingLists" => { list_id => true } }
                  }

                  if provenance["sync_source_metadata"]
                    audit_provenance["sync_source_metadata"] = provenance["sync_source_metadata"]
                  end

                  # Find field provenance for mailing lists
                  # Default list and lists added by safety net won't have field provenance - that's OK
                  field_provenance = provenance["fields"]&.find { |f|
                    f["derived_to_loops_field"] == "mailingLists" &&
                    (f["mailing_list_ids"] || []).include?(list_id)
                  }

                  # Create audit record - wrap in begin/rescue to ensure subscription isn't lost if audit fails
                  begin
                    LoopsContactChangeAudit.create!(
                      occurred_at: now,
                      email_normalized: email_normalized,
                      field_name: "mailingList:#{list_id}",
                      former_loops_value: false,
                      new_loops_value: true,
                      former_sync_source_value: field_provenance&.dig("former_sync_source_value"),
                      new_sync_source_value: field_provenance&.dig("new_sync_source_value"),
                      strategy: "subscribe",
                      sync_source_id: provenance["sync_source_id"],
                      sync_source_table_id: provenance["sync_source_table_id"],
                      sync_source_record_id: provenance["sync_source_record_id"],
                      sync_source_field_id: field_provenance&.dig("sync_source_field_id"),
                      provenance: audit_provenance,
                      request_id: request_id
                    )
                  rescue => e
                    # Log error but don't fail - subscription was created successfully
                    Rails.logger.error("LoopsDispatchWorker: Failed to create audit log for mailingList:#{list_id} for #{email_normalized}: #{e.class} - #{e.message}")
                    Rails.logger.error("LoopsDispatchWorker: Audit log failure backtrace: #{e.backtrace.first(5).join("\n")}")
                  end
                rescue ActiveRecord::RecordNotUnique
                  # Already subscribed - skip silently
                  Rails.logger.debug("LoopsDispatchWorker: User #{email_normalized} already subscribed to list #{list_id}")
                end
              end
            end
          end

          # Determine final status based on what was sent vs filtered
          envelopes.each do |envelope|
            envelope_fields = Set.new(envelope.payload.keys)
            envelope_sent_fields = envelope_fields & sent_fields
            envelope_filtered_fields = envelope_fields & filtered_fields

            # Determine status:
            # - If all fields sent → sent
            # - If some sent, some filtered → partially_sent
            # - If all filtered → ignored_noop (shouldn't happen here, but handle it)
            # - If has validation warnings (e.g., invalid list IDs) → partially_sent

            next if envelope.reload.status == "failed"  # Skip if already marked as failed

            # Check for validation warnings (e.g., invalid mailing list IDs)
            has_validation_warnings = envelope.error.present? &&
                                     envelope.error.is_a?(Hash) &&
                                     envelope.error["validation_warnings"].present?

            if envelope_sent_fields.any? && envelope_filtered_fields.empty? && !has_validation_warnings
              # All envelope fields were sent successfully, no validation warnings
              envelope.update!(status: :sent)
            elsif envelope_sent_fields.any? || has_validation_warnings
              # Some fields sent, some filtered, or has validation warnings
              envelope.update!(status: :partially_sent)
            else
              # All fields filtered (shouldn't happen at this point, but handle it)
              envelope.update!(status: :ignored_noop)
            end
          end
        end
      rescue => e
        # Catch any other unexpected errors in the processing pipeline
        # (errors from update_contact are handled in the inner rescue block)
        Rails.logger.error("LoopsDispatchWorker: Unexpected error processing #{email_normalized}: #{e.class} - #{e.message}")
        Rails.logger.error("LoopsDispatchWorker: Error backtrace: #{e.backtrace.first(10).join("\n")}")

        # Mark envelopes as failed if we have them loaded
        # Skip if envelopes are already marked as failed (e.g., from preflight check)
        if defined?(envelopes) && envelopes && !envelopes.empty?
          # Check if envelopes are already marked as failed
          # Use safe reload that handles deleted records
          already_failed = envelopes.all? do |e|
            begin
              e.reload.status == "failed"
            rescue ActiveRecord::RecordNotFound
              # Envelope was deleted (e.g., in transaction rollback) - skip
              true
            end
          end

          unless already_failed
            ApplicationRecord.transaction do
              envelopes.each do |envelope|
                begin
                  envelope.update_columns(
                    status: :failed,
                    error: {
                      message: e.message,
                      class: e.class.name,
                      stage: "processing",
                      backtrace: e.backtrace.first(10),
                      occurred_at: Time.current.iso8601
                    },
                    updated_at: Time.current
                  )
                rescue ActiveRecord::RecordNotFound
                  # Envelope was deleted - skip
                  next
                end
              end
            end
          end
        end
        if e.is_a?(LoopsService::ApiError) && e.status_code.between?(400, 499)
          Rails.logger.warn("LoopsDispatchWorker: Permanent error (HTTP #{e.status_code}) for #{email_normalized}, not retrying: #{e.message}")
          return
        end

        raise
      ensure
        # Always release the lock
        connection.execute(
          "SELECT pg_advisory_unlock(#{lock_key})"
        )
      end
    end
  end

  # Hash email to integer for advisory lock (same as PrepareLoopsFieldsForOutboxJob)
  def email_to_lock_key(email)
    # Combine namespace and email hash into single bigint
    # Use first 8 bytes of SHA256 hash as integer, combine with namespace
    hash_int = Digest::SHA256.hexdigest(email)[0..15].to_i(16)
    # Combine namespace (upper 32 bits) and hash (lower 32 bits)
    (ADVISORY_LOCK_NAMESPACE.to_i << 32) | (hash_int & 0xFFFFFFFF)
  end

  # Merge multiple envelopes: combine payloads, latest modified_at wins per field
  def merge_envelopes(envelopes)
    merged = {}

    envelopes.each do |envelope|
      envelope.payload.each do |field_name, field_data|
        existing = merged[field_name]

        if existing.nil?
          merged[field_name] = field_data.dup
        else
          # Compare modified_at timestamps - keep latest
          # Handle both string and symbol keys (JSONB from DB has string keys)
          existing_hash = existing.is_a?(Hash) ? existing : {}
          field_data_hash = field_data.is_a?(Hash) ? field_data : {}

          existing_modified_at = existing_hash[:modified_at] || existing_hash["modified_at"]
          new_modified_at = field_data_hash[:modified_at] || field_data_hash["modified_at"]

          existing_time = Time.parse(existing_modified_at.to_s) rescue Time.at(0)
          new_time = Time.parse(new_modified_at.to_s) rescue Time.at(0)

          if new_time > existing_time
            merged[field_name] = field_data.dup
          end
        end
      end
    end

    merged
  end

  # Filter by loops_field_baselines: drop fields whose value equals baseline and hasn't expired
  # For :override strategy fields, always include (even if value matches baseline)
  def filter_by_baselines(email_normalized, merged_payload)
    filtered = {}

    merged_payload.each do |field_name, field_data|
      # Skip mailingLists - it's handled separately via LoopsListSubscription table
      if field_name == "mailingLists" || field_name == :mailingLists
        filtered[field_name] = field_data
        next
      end

      # Handle both string and symbol keys
      field_data_hash = field_data.is_a?(Hash) ? field_data : {}
      current_value = field_data_hash[:value] || field_data_hash["value"]
      strategy = (field_data_hash[:strategy] || field_data_hash["strategy"])&.to_sym || :upsert

      # For override strategy, always include (even if value matches baseline)
      # This allows override fields to explicitly set null values
      if strategy == :override
        filtered[field_name] = field_data
        next
      end

      baseline = LoopsFieldBaseline.find_by(
        email_normalized: email_normalized,
        field_name: field_name
      )

      if baseline.nil?
        # No baseline - include field
        filtered[field_name] = field_data
      elsif baseline.expires_at && baseline.expires_at < Time.current
        # Baseline expired - include field
        filtered[field_name] = field_data
      elsif baseline.last_sent_value.to_json != current_value.to_json
        # Value changed - include field
        filtered[field_name] = field_data
      else
        # Value unchanged and not expired - skip field
        Rails.logger.debug("LoopsDispatchWorker: Skipping #{field_name} for #{email_normalized} - unchanged")
      end
    end

    filtered
  end

  # Apply strategies: :upsert (only update if value is not nil), :override (always update)
  def apply_strategies(filtered_payload)
    result = {}

    filtered_payload.each do |field_name, field_data|
      # Handle both string and symbol keys
      field_data_hash = field_data.is_a?(Hash) ? field_data : {}
      strategy = (field_data_hash[:strategy] || field_data_hash["strategy"])&.to_sym || :upsert
      value = field_data_hash[:value] || field_data_hash["value"]

      case strategy
      when :upsert
        # Only include if value is not nil
        if value != nil
          result[field_name] = value
        end
      when :override
        # Always include (even if nil)
        result[field_name] = value
      else
        # Unknown strategy - default to upsert behavior
        if value != nil
          result[field_name] = value
        end
      end
    end

    result
  end

  # Process mailing lists: idempotence check, default list injection, catalog sync, validation
  def process_mailing_lists(merged_payload, email_normalized, sync_source, contact_exists, envelopes)
    # Extract list IDs from payload
    list_ids = extract_mailing_lists_list_ids(merged_payload)

    # Step 2: Add default list for new contacts if needed
    if sync_source && !contact_exists
      list_ids = add_default_list_if_needed(email_normalized, list_ids)

      # Also inject other initial fields (userGroup, source)
      inject_initial_fields_for_new_contact(merged_payload, sync_source, email_normalized)
    end

    # Return early if no lists to process
    if list_ids.empty?
      update_mailing_lists_payload(merged_payload, [])
      return
    end

    # Step 1: Idempotence check - filter out already-subscribed lists
    list_ids = filter_idempotent_lists(email_normalized, list_ids)

    # Return early if all lists were already subscribed
    if list_ids.empty?
      update_mailing_lists_payload(merged_payload, [])
      return
    end

    # Step 3: Ensure catalog is populated before validation
    ensure_catalog_populated

    # Step 4: Validate list IDs against catalog
    validation_result = validate_list_ids(list_ids)

    # Store validation warnings in envelopes if invalid IDs found
    if validation_result[:invalid_list_ids].any?
      store_validation_warnings(envelopes, validation_result[:invalid_list_ids], sync_source, contact_exists)
    end

    # Update payload with validated list IDs
    update_mailing_lists_payload(merged_payload, validation_result[:valid_list_ids])
  end

  # Extract mailing list IDs from payload (handles string/symbol keys)
  def extract_mailing_lists_list_ids(payload)
    data = payload["mailingLists"] || payload[:mailingLists]
    return [] unless data.is_a?(Hash)

    value = data[:value] || data["value"] || {}
    return [] unless value.is_a?(Hash)

    value.select { |_id, subscribed| subscribed == true }.keys
  end

  # Filter out already-subscribed lists (idempotence check)
  def filter_idempotent_lists(email_normalized, list_ids)
    return [] if list_ids.empty?

    already_subscribed = LoopsListSubscription.where(
      email_normalized: email_normalized,
      list_id: list_ids
    ).pluck(:list_id).to_set

    (list_ids.to_set - already_subscribed).to_a
  end

  # Add default list for new contacts if not already subscribed
  def add_default_list_if_needed(email_normalized, list_ids)
    default_id = ENV["DEFAULT_LOOPS_LIST_ID"].presence
    return list_ids unless default_id

    # Skip if already in list or already subscribed
    return list_ids if list_ids.include?(default_id)
    return list_ids if LoopsListSubscription.exists?(
      email_normalized: email_normalized,
      list_id: default_id
    )

    list_ids + [ default_id ]
  end

  # Inject initial fields (userGroup, source) for new contacts
  def inject_initial_fields_for_new_contact(merged_payload, sync_source, email_normalized)
    initial_fields = LoopsFieldBaseline.initial_payload_for_new_contact(sync_source)
    initial_fields.each do |field_name, field_data|
      # Skip mailingLists - we handle it separately above
      next if field_name == "mailingLists" || field_name == :mailingLists

      # Only add if not already present (queued envelopes take precedence)
      merged_payload[field_name] ||= field_data
    end
  end

  # Ensure LoopsList catalog is populated (sync if empty)
  def ensure_catalog_populated
    return if LoopsList.count > 0

    Rails.logger.info("LoopsDispatchWorker: LoopsList catalog is empty, syncing lists before validation")

    # Use advisory lock to prevent concurrent syncs
    lock_id = 0x4C4C5353  # ASCII: "LLSS" (Loops List Sync)

    ActiveRecord::Base.connection_pool.with_connection do |connection|
      result = connection.execute("SELECT pg_try_advisory_lock(#{lock_id})")
      lock_acquired = result.first["pg_try_advisory_lock"]

      if lock_acquired
        begin
          # Double-check after acquiring lock (another process might have populated it)
          SyncLoopsListsWorker.new.perform if LoopsList.count == 0
        ensure
          connection.execute("SELECT pg_advisory_unlock(#{lock_id})")
        end
      else
        # Another process is syncing - wait briefly and check again
        sleep(0.5)
        if LoopsList.count == 0
          Rails.logger.warn("LoopsDispatchWorker: Catalog still empty after sync attempt, proceeding with validation")
        end
      end
    end
  end

  # Validate list IDs against catalog
  def validate_list_ids(list_ids)
    return { valid_list_ids: [], invalid_list_ids: [] } if list_ids.empty?

    known_list_ids = LoopsList.where(loops_list_id: list_ids)
                              .pluck(:loops_list_id)
                              .to_set

    valid_list_ids = (list_ids.to_set & known_list_ids).to_a
    invalid_list_ids = (list_ids.to_set - known_list_ids).to_a

    { valid_list_ids: valid_list_ids, invalid_list_ids: invalid_list_ids }
  end

  # Update payload with validated list IDs (or remove if empty)
  def update_mailing_lists_payload(payload, valid_list_ids)
    if valid_list_ids.empty?
      payload.delete("mailingLists")
      payload.delete(:mailingLists)
    else
      payload["mailingLists"] = {
        value: valid_list_ids.index_with { true },
        strategy: :override,
        modified_at: Time.current.iso8601
      }
    end
  end

  # Store validation warnings in envelopes
  def store_validation_warnings(envelopes, invalid_list_ids, sync_source, contact_exists)
    envelopes.each do |envelope|
      # Only update if this envelope contains mailingLists OR if we added default list
      has_mailing_lists = envelope.payload.key?("mailingLists") || envelope.payload.key?(:mailingLists)
      is_default_list_case = sync_source && !contact_exists && invalid_list_ids.include?(ENV["DEFAULT_LOOPS_LIST_ID"].presence)
      next unless has_mailing_lists || is_default_list_case

      # Merge validation warnings with existing error content
      existing_error = envelope.error || {}
      existing_error = existing_error.dup if existing_error.is_a?(Hash)
      existing_error["validation_warnings"] = {
        invalid_list_ids: invalid_list_ids,
        message: "Some mailing list IDs were not found in Loops catalog",
        occurred_at: Time.current.iso8601
      }

      envelope.update_columns(
        error: existing_error,
        updated_at: Time.current
      )
    end
  end
end
