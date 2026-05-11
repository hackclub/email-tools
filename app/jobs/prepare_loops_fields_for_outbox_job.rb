require_relative "../lib/email_normalizer"
# Rails autoloads classes in app/ directories, so no need for explicit requires

class PrepareLoopsFieldsForOutboxJob
  include Sidekiq::Worker

  sidekiq_options queue: :default

  # OUTPUT ENVELOPE FORMAT
  # ======================
  #
  # The output envelope is a Hash where:
  # - Keys are Loops field names (strings)
  # - Values are field metadata hashes with the following structure:
  #
  #   {
  #     "loops_field_name" => {
  #       value: <any>,           # The actual value to send to Loops (required)
  #       strategy: :upsert,      # Field update strategy: :upsert or :override (required)
  #       modified_at: "2025-11-02T21:00:00Z"  # ISO8601 timestamp (required)
  #     }
  #   }
  #
  # Example:
  #   {
  #     "tmpZachLoopsApiTest" => {
  #       value: "hi",
  #       strategy: :upsert,
  #       modified_at: "2025-11-02T21:00:00Z"
  #     }
  #   }
  #
  # Strategy meanings:
  # - :upsert: Only update if value is not nil (skip nil values)
  # - :override: Always update, even if value is nil
  #
  # Field name mapping:
  # - Sync source field names are mapped to Loops field names by stripping prefixes:
  #   - "Loops - tmpZachLoopsApiTest" → "tmpZachLoopsApiTest" (strategy: :upsert)
  #   - "Loops - Override - tmpZachLoopsApiTest2" → "tmpZachLoopsApiTest2" (strategy: :override)
  # - Strategy is determined by the presence of "Override" in the field name

  def perform(email, sync_source_id, table_id, record_id, changed_fields)
    # Process all Loops fields from changed_fields
    # changed_fields format:
    # {
    #   "field_id/field_name" => {
    #     "value" => <current_value>,
    #     "old_value" => <previous_value> or nil,
    #     "modified_at" => "ISO8601 timestamp"
    #   }
    # }

    # Normalize email
    email_normalized = EmailNormalizer.normalize(email)
    return unless email_normalized

    # Build envelope by processing all Loops fields from changed_fields
    envelope = {}
    provenance_fields = []

    changed_fields.each do |field_key, field_data|
      # Extract field name from key (format: "field_id/field_name")
      field_name = field_key.split("/", 2).last

      # Skip if not a Loops field (must start with "Loops - ", "Loops - Override - ", or "Loops List - ")
      is_loops_field = field_name.match?(/\ALoops\s*-\s*/i) || field_name.match?(/\ALoops\s+List\s*-\s*/i)
      next unless is_loops_field

      # Extract field_id from key
      field_id = field_key.split("/", 2).first

      # Check if this is a special AI field
      special_match = field_name.match(/\ALoops\s*-\s*Special\s*-\s*(setFullName|setFullAddress)\z/i)

      if special_match
        # Handle special AI fields
        special_field_type = special_match[1]
        value = field_data["value"]
        old_value = field_data["old_value"]
        modified_at = field_data["modified_at"] || Time.current.iso8601

        next if value.blank?

        # Call appropriate processor based on field type
        extracted_data = case special_field_type
        when /setFullName/i
          AiProcessors::ExtractFullName.call(raw_input: value.to_s)
        when /setFullAddress/i
          AiProcessors::ExtractFullAddress.call(raw_input: value.to_s)
        else
          {}
        end

        # Convert extracted data to envelope format
        extracted_data.each do |loops_field, field_value|
          # Use override strategy for setFullAddress, upsert for setFullName
          strategy = (special_field_type =~ /setFullAddress/i) ? :override : :upsert

          envelope[loops_field] = {
            value: field_value,
            strategy: strategy,
            modified_at: modified_at
          }

          # Add provenance
          provenance_fields << {
            sync_source_field_id: field_id,
            sync_source_field_name: field_name,
            former_sync_source_value: old_value,
            new_sync_source_value: value,
            modified_at: modified_at,
            derived_to_loops_field: loops_field
          }
        end

        # For addresses, also set addressLastUpdatedAt with override strategy
        if special_field_type =~ /setFullAddress/i && extracted_data.any?
          now = Time.current.iso8601
          envelope["addressLastUpdatedAt"] = {
            value: now,
            strategy: :override,
            modified_at: now
          }

          provenance_fields << {
            sync_source_field_id: field_id,
            sync_source_field_name: field_name,
            former_sync_source_value: old_value,
            new_sync_source_value: value,
            modified_at: now,
            derived_to_loops_field: "addressLastUpdatedAt"
          }
        end

        next
      end

      # Check if this is a "Loops List - ..." field
      list_match = field_name.match(/\ALoops\s+List\s*-\s*(.+)\z/i)

      if list_match
        # Handle mailing list fields
        value = field_data["value"]
        old_value = field_data["old_value"]
        modified_at = field_data["modified_at"] || Time.current.iso8601

        # Skip if value is blank
        next if value.blank?

        # Parse comma-separated list IDs
        list_ids = value.to_s.split(",").map { |s| s.strip }.reject(&:blank?).uniq
        next if list_ids.empty?

        # Initialize or merge into mailingLists envelope entry
        if envelope["mailingLists"]
          # Merge with existing mailingLists
          existing_value = envelope["mailingLists"][:value] || envelope["mailingLists"]["value"] || {}
          existing_value = existing_value.dup if existing_value.is_a?(Hash)
          list_ids.each { |id| existing_value[id] = true }
          envelope["mailingLists"][:value] = existing_value
        else
          # Create new mailingLists entry
          envelope["mailingLists"] = {
            value: list_ids.index_with { true },
            strategy: :override,
            modified_at: modified_at
          }
        end

        # Add provenance
        provenance_fields << {
          sync_source_field_id: field_id,
          sync_source_field_name: field_name,
          former_sync_source_value: old_value,
          new_sync_source_value: value,
          modified_at: modified_at,
          derived_to_loops_field: "mailingLists",
          mailing_list_ids: list_ids
        }

        next
      end

      # Extract field name without prefix to check if it's lowerCamelCase
      field_name_without_prefix = field_name.sub(/\ALoops\s*-\s*(Override\s*-\s*)?/i, "")

      # Skip if field name doesn't start with lowercase (not lowerCamelCase)
      # This prevents matching fields like "Loops - Lists" which starts with uppercase
      next unless field_name_without_prefix =~ /\A[a-z]/

      # Map field name and determine strategy
      loops_field_name, strategy = map_field_name_and_strategy(field_name)

      # Extract values
      value = field_data["value"]
      old_value = field_data["old_value"]
      modified_at = field_data["modified_at"] || Time.current.iso8601

      # Add to envelope
      envelope[loops_field_name] = {
        value: value,
        strategy: strategy,
        modified_at: modified_at
      }

      # Add to provenance fields
      provenance_fields << {
        sync_source_field_id: field_id,
        sync_source_field_name: field_name,
        former_sync_source_value: old_value,
        new_sync_source_value: value,
        modified_at: modified_at
      }
    end

    # Skip if no Loops fields found
    return if envelope.empty?

    # Build provenance
    provenance = build_provenance(sync_source_id, table_id, record_id, provenance_fields)

    # Write to outbox
    LoopsOutboxEnvelope.create!(
      email_normalized: email_normalized,
      payload: envelope,
      status: :queued,
      provenance: provenance,
      sync_source_id: sync_source_id
    )
  end

  private

  # Map sync source field name to Loops field name and determine strategy
  # Examples:
  #   "Loops - tmpZachLoopsApiTest" → ["tmpZachLoopsApiTest", :upsert]
  #   "Loops - Override - tmpZachLoopsApiTest2" → ["tmpZachLoopsApiTest2", :override]
  def map_field_name_and_strategy(field_name)
    # Check if field name contains "Override"
    has_override = field_name =~ /\ALoops\s*-\s*Override\s*-\s*/i

    if has_override
      # Strip "Loops - Override - " prefix
      loops_field_name = field_name.sub(/\ALoops\s*-\s*Override\s*-\s*/i, "")
      strategy = :override
    else
      # Strip "Loops - " prefix
      loops_field_name = field_name.sub(/\ALoops\s*-\s*/i, "")
      strategy = :upsert
    end

    [ loops_field_name, strategy ]
  end

  # Build provenance metadata
  def build_provenance(sync_source_id, table_id, record_id, fields_array)
    sync_source = SyncSource.find_by(id: sync_source_id)
    sync_source_type = sync_source&.source || "unknown"

    provenance = {
      sync_source_id: sync_source_id,
      sync_source_type: sync_source_type,
      sync_source_table_id: table_id,
      sync_source_record_id: record_id,
      fields: fields_array,
      created_from: "#{sync_source_type}_poller"
    }

    if sync_source
      provenance[:sync_source_metadata] = {
        source_id: sync_source.source_id
      }.merge(sync_source.metadata || {})
    end

    provenance
  end
end
