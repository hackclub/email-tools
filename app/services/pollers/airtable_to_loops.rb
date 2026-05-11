module Pollers
  class AirtableToLoops
    require_relative "../../lib/email_normalizer"
    require_relative "../../lib/value_normalizer"

    DISPLAY_NAME_UPDATE_INTERVAL = 24.hours

    def call(sync_source)
      base_id = sync_source.source_id
      poll_start_time = Time.current.utc

      log_header("Processing Airtable Base: #{base_id}")

      update_display_name_if_stale(sync_source, base_id)

      # Get all tables for the base
      tables = AirtableService::Bases.get_schema(base_id: base_id)

      log_info("Found #{tables.size} table(s)")

      # Iterate through each table
      tables.each do |table_id, table|
        process_table(sync_source, base_id, table_id, table)
      end

      # Update cursor to poll start time after successful processing
      sync_source.update_columns(cursor: poll_start_time.utc.iso8601(3))

      log_header("Finished processing base #{base_id}")
    end

    private

    def process_table(sync_source, base_id, table_id, table)
      table_name = table["name"] || table_id
      log_section("Table: #{table_name} (ID: #{table_id})")

      # Print schema for debugging
      log_schema(table)

      # Validate required fields
      email_field = find_email_field(table)
      unless email_field
        log_info("Skipping table - no 'email' field found")
        return
      end

      loops_fields = find_loops_fields(table)
      if loops_fields.empty?
        log_info("Skipping table - no 'Loops - ...' fields found")
        return
      end

      log_info("Found email field: #{email_field['name']}")
      log_info("Found #{loops_fields.size} Loops field(s): #{loops_fields.values.map { |f| f['name'] }.join(', ')}")

      metadata = sync_source.metadata || {}
      known_loops_fields = metadata["known_loops_fields"] || {}
      previously_known_field_map = known_loops_fields[table_id] || {}

      unless previously_known_field_map.is_a?(Hash)
        previously_known_field_map = {}
      end

      current_field_map = loops_fields.map do |field_id, field|
        field_type = field["type"] || "unknown"
        value = if field_type == "formula"
          formula = field.dig("options", "formula") || ""
          "formula:#{formula}"
        else
          field_type
        end
        [ field_identifier(field_id, field["name"]), value ]
      end.to_h

      current_field_ids = current_field_map.keys
      previously_known_field_ids = previously_known_field_map.keys

      has_new_loops_fields = (current_field_ids - previously_known_field_ids).any?
      has_changed_field_types = current_field_ids.any? do |field_id|
        previously_known_field_map.key?(field_id) &&
          previously_known_field_map[field_id] != current_field_map[field_id]
      end

      needs_full_resync = has_new_loops_fields || has_changed_field_types

      if has_new_loops_fields
        new_field_ids = current_field_ids - previously_known_field_ids
        log_info("New Loops field(s) detected: #{new_field_ids.join(', ')} - fetching ALL records for this table")
      end

      if has_changed_field_types
        changed_fields = current_field_ids.select do |field_id|
          previously_known_field_map.key?(field_id) &&
            previously_known_field_map[field_id] != current_field_map[field_id]
        end
        log_info("Field type or formula change(s) detected for: #{changed_fields.join(', ')} - fetching ALL records for this table")
      end

      filter_formula = build_filter_formula(sync_source, email_field, skip_time_filter: needs_full_resync)
      records = fetch_records(base_id, table_id, filter_formula, email_field: email_field, fetch_all: needs_full_resync)

      if records.empty?
        log_info("No records to process")
        update_known_loops_fields(sync_source, table_id, current_field_map)
        return
      end

      log_info("Processing #{records.size} record(s) for change detection")

      changed_records = detect_changes(sync_source, base_id, table_id, records, table, email_field, loops_fields)
      process_changed_records(sync_source.id, table_id, changed_records, loops_fields)

      update_known_loops_fields(sync_source, table_id, current_field_map)
    end

    def find_email_field(table)
      return nil unless table["fields"]

      table["fields"].find do |field|
        field_name = field["name"] || ""
        field_name.strip.downcase == "email"
      end
    end

    def find_loops_fields(table)
      return {} unless table["fields"]

      # Match fields starting with "Loops - ", "Loops - Override - ", "Loops - Special - ", or "Loops List - "
      # Field name must be lowerCamelCase (starts with lowercase letter) for "Loops - ..." fields
      # "Loops List - ..." fields can have any name after the prefix
      loops_pattern = /\ALoops\s*-\s*(Override\s*-\s*|Special\s*-\s*)?[a-z][a-zA-Z0-9]*\z/i
      loops_list_pattern = /\ALoops\s+List\s*-\s*.+\z/i

      loops_fields = {}
      table["fields"].each do |field|
        field_name = field["name"] || ""

        # Check for "Loops List - ..." fields
        if field_name.strip.match?(loops_list_pattern)
          loops_fields[field["id"]] = field
          next
        end

        # Check for regular "Loops - ..." fields (must start with lowercase after prefix)
        if field_name.strip.match?(loops_pattern)
          field_name_without_prefix = field_name.sub(/\ALoops\s*-\s*(Override\s*-\s*|Special\s*-\s*)?/i, "")
          if field_name_without_prefix =~ /\A[a-z]/
            loops_fields[field["id"]] = field
          end
        end
      end

      loops_fields
    end

    # Generate field identifier in format "field_id/field_name" for Airtable fields
    def field_identifier(field_id, field_name)
      "#{field_id}/#{field_name}"
    end

    # Generate row identifier in format "table_id/record_id" for Airtable records
    def row_identifier(table_id, record_id)
      "#{table_id}/#{record_id}"
    end

    def build_filter_formula(sync_source, email_field, skip_time_filter: false)
      conditions = []

      # Email validation: matches pattern .+@.+\..+
      # Check: not empty, contains '@', contains '.' after '@', has content before '@'
      email_field_name = email_field["name"]
      # FIND('@', {Email}) > 0 ensures @ exists and there's content before it
      # FIND('.', {Email}, FIND('@', {Email})) ensures . exists after @
      # LEN ensures not empty
      email_condition = "AND(LEN({#{email_field_name}}) > 0, FIND('@', {#{email_field_name}}) > 0, FIND('@', {#{email_field_name}}) < LEN({#{email_field_name}}), FIND('.', {#{email_field_name}}, FIND('@', {#{email_field_name}})) > 0, FIND('.', {#{email_field_name}}, FIND('@', {#{email_field_name}})) < LEN({#{email_field_name}}))"
      conditions << email_condition

      # Time-based filtering (if we have a cursor and not skipping time filter)
      unless skip_time_filter
        cursor_timestamp = sync_source.cursor
        if cursor_timestamp
          # Cursor is stored as JSONB string (ISO8601 timestamp)
          # Rails automatically deserializes JSONB strings to Ruby strings
          cursor_time_str = cursor_timestamp.to_s

          # Parse cursor time and subtract 5 minutes to account for propagation delays
          # Sometimes changes haven't fully propagated by the time we make the API request
          begin
            cursor_time = Time.parse(cursor_time_str).utc - 5.minutes
            cursor_time_adjusted = cursor_time.iso8601(3)
          rescue => e
            # If parsing fails, fall back to original cursor time
            log_error("Failed to parse cursor timestamp: #{e.message}, using original: #{cursor_time_str}")
            cursor_time_adjusted = cursor_time_str
          end

          time_condition = "OR(LAST_MODIFIED_TIME() > \"#{cursor_time_adjusted}\", CREATED_TIME() > \"#{cursor_time_adjusted}\")"
          conditions << time_condition
        end
      end

      # Combine all conditions with AND
      if conditions.size > 1
        "AND(#{conditions.join(', ')})"
      elsif conditions.size == 1
        conditions.first
      else
        email_condition # fallback to just email check
      end
    end

    def fetch_records(base_id, table_id, filter_formula, email_field: nil, fetch_all: false)
      # Always use pagination to handle all cases (with or without filter_formula)
      # Airtable's offset-based pagination is safe for preventing race conditions
      # The offset token provided by Airtable is stable and handles concurrent changes
      records = []

      begin
        if fetch_all
          # When fetching all records, we don't use filter_formula (skip time filter)
          # Apply email validation filter manually since we're fetching everything
          AirtableService::Records.find_each(base_id: base_id, table_id: table_id) do |record|
            record_fields = record["fields"] || {}

            if email_field
              email_value = record_fields[email_field["name"]]
              # Validate email pattern: .+@.+\..+ (same pattern as in build_filter_formula)
              if email_value && email_value.to_s =~ /.+@.+\..+/
                records << record
              end
            else
              # If no email field provided, include all records (shouldn't happen in practice)
              records << record
            end
          end
        else
          # Use filter_formula (includes email validation and time filter if applicable)
          # Pagination will handle cases where filter_formula returns more than 100 records
          AirtableService::Records.find_each(
            base_id: base_id,
            table_id: table_id,
            filter_formula: filter_formula
          ) do |record|
            records << record
          end
        end

        records
      rescue => e
        log_error("Error fetching records: #{e.class.name} - #{e.message}")
        []
      end
    end

    def detect_changes(sync_source, base_id, table_id, records, table, email_field, loops_fields)
      changed_records = []

      records.each do |record|
        record_id = record["id"]
        row_id = row_identifier(table_id, record_id)
        record_fields = record["fields"] || {}
        changed_values = {}

        # Only iterate through Loops fields - we only create baselines for Loops fields
        loops_fields.each do |field_id, field|
          field_name = field["name"]
          field_id_key = field_identifier(field_id, field_name)

          # Get current value from record_fields (nil if not present, meaning field is null/empty)
          current_value_raw = record_fields[field_name]
          current_value = ValueNormalizer.from_airtable(current_value_raw)

          result = FieldValueBaseline.detect_change(
            sync_source: sync_source,
            row_id: row_id,
            field_id: field_id_key,
            current_value: current_value
          )

          if result[:changed]
            # Include old_value and modified_at for the job
            # old_value comes from the result (nil if first_time)
            # Use string keys for Sidekiq JSON serialization compatibility
            changed_values[field_id_key] = {
              "value" => current_value,
              "old_value" => result[:old_value],
              "modified_at" => Time.current.iso8601
            }
          end
        end

        # If ANY field changed, send to the job
        unless changed_values.empty?
          email = record_fields[email_field["name"]]
          changed_records << {
            id: record_id,
            email: email,
            changedValues: changed_values
          }
        end
      end

      changed_records
    end

    def process_changed_records(sync_source_id, table_id, changed_records, loops_fields)
      if changed_records.empty?
        log_info("No changed records found")
        return
      end

      log_info("Found #{changed_records.size} record(s) with changes")

      changed_records.each do |changed_record|
        record_id = changed_record[:id]
        email = changed_record[:email]

        # Normalize email
        normalized_email = EmailNormalizer.normalize(email)
        next unless normalized_email # Skip if blank/invalid

        # Build changed_fields hash (already in correct format from detect_changes)
        changed_fields = changed_record[:changedValues]

        # Enqueue job
        PrepareLoopsFieldsForOutboxJob.perform_async(
          email,
          sync_source_id,
          table_id,
          record_id,
          changed_fields
        )
      end
    end

    # Logging helpers
    def log_header(message)
      puts "\n=== #{message} ===\n"
    end

    def log_section(message)
      puts "\n" + "=" * 80
      puts message
      puts "=" * 80
    end

    def log_info(message)
      puts message
    end

    def log_error(message)
      puts "ERROR: #{message}"
    end

    def log_schema(table)
      puts "\nSchema:"
      puts "-" * 80
      puts "Fields:"
      if table["fields"] && table["fields"].any?
        table["fields"].each do |field|
          field_type = field["type"] || "unknown"
          field_name = field["name"] || field["id"]
          puts "  - #{field_name} (#{field_type})"
        end
      else
        puts "  (no fields found)"
      end
    end

    def update_known_loops_fields(sync_source, table_id, current_field_map)
      metadata = sync_source.metadata || {}
      metadata["known_loops_fields"] ||= {}
      metadata["known_loops_fields"][table_id] = current_field_map
      sync_source.update_columns(metadata: metadata)
    end

    def update_display_name_if_stale(sync_source, base_id)
      return unless sync_source.is_a?(AirtableSyncSource)

      # Check if we need to update display_name
      should_update = sync_source.display_name_updated_at.nil? ||
                      sync_source.display_name_updated_at < DISPLAY_NAME_UPDATE_INTERVAL.ago

      return unless should_update

      begin
        base = AirtableService::Bases.find_by_id(base_id: base_id)
        if base && base["name"]
          sync_source.update_columns(
            display_name: base["name"],
            display_name_updated_at: Time.current
          )
          log_info("Updated display_name to: #{base["name"]}")
        end
      rescue => e
        # Log error but don't fail the poll if name update fails
        log_error("Failed to update display_name: #{e.class.name} - #{e.message}")
      end
    end
  end
end
