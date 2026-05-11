require "test_helper"
require "minitest/mock"

module Pollers
  class AirtableToLoopsTest < ActiveSupport::TestCase
    def setup
      @sync_source = SyncSource.create!(
        source: "airtable",
        source_id: "app123",
        poll_interval_seconds: 30
      )
    end

    def teardown
      FieldValueBaseline.destroy_all
      SyncSource.destroy_all
    end

    test "detect_changes only creates baselines for Loops fields" do
      # Create mock table schema with both Loops and non-Loops fields
      table = {
        "fields" => [
          { "id" => "fldEmail", "name" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - firstName" },
          { "id" => "fldLoops2", "name" => "Loops - lastName" },
          { "id" => "fldNonLoops1", "name" => "Zapier - Added to Midnight Loops list at" },
          { "id" => "fldNonLoops2", "name" => "referral_target" },
          { "id" => "fldNonLoops3", "name" => "inbound_referrals" }
        ]
      }

      email_field = { "id" => "fldEmail", "name" => "email" }

      # Find Loops fields (this matches the actual logic)
      loops_fields = {}
      table["fields"].each do |field|
        field_name = field["name"] || ""
        loops_pattern = /\ALoops\s*-\s*(Override\s*-\s*|Special\s*-\s*)?[a-z][a-zA-Z0-9]*\z/i
        if field_name.strip.match?(loops_pattern)
          field_name_without_prefix = field_name.sub(/\ALoops\s*-\s*(Override\s*-\s*|Special\s*-\s*)?/i, "")
          if field_name_without_prefix =~ /\A[a-z]/
            loops_fields[field["id"]] = field
          end
        end
      end

      # Verify we found the Loops fields
      assert_equal 2, loops_fields.size, "Should find 2 Loops fields"
      assert loops_fields.key?("fldLoops1"), "Should include Loops - firstName"
      assert loops_fields.key?("fldLoops2"), "Should include Loops - lastName"

      # Create mock records with values for all fields
      records = [
        {
          "id" => "rec123",
          "fields" => {
            "email" => "test@example.com",
            "Loops - firstName" => "John",
            "Loops - lastName" => "Doe",
            "Zapier - Added to Midnight Loops list at" => "2024-01-01",
            "referral_target" => "target123",
            "inbound_referrals" => [ "ref1", "ref2" ]
          }
        }
      ]

      # Call detect_changes
      poller = Pollers::AirtableToLoops.new
      changed_records = poller.send(
        :detect_changes,
        @sync_source,
        "base123",
        "tbl123",
        records,
        table,
        email_field,
        loops_fields
      )

      # Verify only Loops field baselines were created
      baselines = FieldValueBaseline.where(sync_source: @sync_source)
      baseline_field_ids = baselines.pluck(:field_id)

      # Should only have baselines for Loops fields (format: "field_id/field_name")
      assert_equal 2, baselines.count, "Should create 2 baselines (one for each Loops field)"

      assert baseline_field_ids.any? { |id| id.include?("Loops - firstName") },
        "Should have baseline for Loops - firstName"
      assert baseline_field_ids.any? { |id| id.include?("Loops - lastName") },
        "Should have baseline for Loops - lastName"

      # Verify non-Loops fields did NOT create baselines
      assert baseline_field_ids.none? { |id| id.include?("Zapier") },
        "Should NOT have baseline for Zapier field"
      assert baseline_field_ids.none? { |id| id.include?("referral_target") },
        "Should NOT have baseline for referral_target"
      assert baseline_field_ids.none? { |id| id.include?("inbound_referrals") },
        "Should NOT have baseline for inbound_referrals"
    end

    test "find_loops_fields detects Special fields" do
      table = {
        "fields" => [
          { "id" => "fldEmail", "name" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - tmpZachLoopsApiTest" },
          { "id" => "fldLoops2", "name" => "Loops - Override - tmpZachLoopsApiTest2" },
          { "id" => "fldSpecial1", "name" => "Loops - Special - setFullName" },
          { "id" => "fldSpecial2", "name" => "Loops - Special - setFullAddress" },
          { "id" => "fldNonLoops1", "name" => "Loops - Lists" }, # Should NOT match (uppercase)
          { "id" => "fldNonLoops2", "name" => "Loop - Special - setFullAddress" } # Typo - should NOT match
        ]
      }

      poller = Pollers::AirtableToLoops.new
      loops_fields = poller.send(:find_loops_fields, table)

      # Should find 4 Loops fields
      assert_equal 4, loops_fields.size, "Should find 4 Loops fields"
      assert loops_fields.key?("fldLoops1"), "Should include regular Loops field"
      assert loops_fields.key?("fldLoops2"), "Should include Override Loops field"
      assert loops_fields.key?("fldSpecial1"), "Should include Special - setFullName"
      assert loops_fields.key?("fldSpecial2"), "Should include Special - setFullAddress"
      assert_not loops_fields.key?("fldNonLoops1"), "Should NOT include Loops - Lists (uppercase)"
      assert_not loops_fields.key?("fldNonLoops2"), "Should NOT include typo 'Loop - Special'"
    end

    test "detect_changes correctly identifies changed Loops fields" do
      table = {
        "fields" => [
          { "id" => "fldEmail", "name" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - firstName" }
        ]
      }

      email_field = { "id" => "fldEmail", "name" => "email" }
      loops_fields = { "fldLoops1" => { "id" => "fldLoops1", "name" => "Loops - firstName" } }

      # First record with initial value
      records1 = [
        {
          "id" => "rec123",
          "fields" => {
            "email" => "test@example.com",
            "Loops - firstName" => "John"
          }
        }
      ]

      poller = Pollers::AirtableToLoops.new

      # First call - should detect change (first time)
      changed_records1 = poller.send(
        :detect_changes,
        @sync_source,
        "base123",
        "tbl123",
        records1,
        table,
        email_field,
        loops_fields
      )

      assert_equal 1, changed_records1.size, "Should detect change on first time"
      assert_equal 1, changed_records1.first[:changedValues].size, "Should have one changed field"

      # Second call with same value - should not detect change
      changed_records2 = poller.send(
        :detect_changes,
        @sync_source,
        "base123",
        "tbl123",
        records1,
        table,
        email_field,
        loops_fields
      )

      assert_equal 0, changed_records2.size, "Should not detect change for same value"

      # Third call with different value - should detect change
      records2 = [
        {
          "id" => "rec123",
          "fields" => {
            "email" => "test@example.com",
            "Loops - firstName" => "Jane"
          }
        }
      ]

      changed_records3 = poller.send(
        :detect_changes,
        @sync_source,
        "base123",
        "tbl123",
        records2,
        table,
        email_field,
        loops_fields
      )

      assert_equal 1, changed_records3.size, "Should detect change when value changes"
      assert_equal "Jane", changed_records3.first[:changedValues].values.first["value"]
      assert_equal "John", changed_records3.first[:changedValues].values.first["old_value"]
    end

    test "detect_changes handles empty loops_fields gracefully" do
      table = {
        "fields" => [
          { "id" => "fldEmail", "name" => "email" },
          { "id" => "fldNonLoops1", "name" => "some_field" }
        ]
      }

      email_field = { "id" => "fldEmail", "name" => "email" }
      loops_fields = {} # Empty - no Loops fields

      records = [
        {
          "id" => "rec123",
          "fields" => {
            "email" => "test@example.com",
            "some_field" => "some_value"
          }
        }
      ]

      poller = Pollers::AirtableToLoops.new
      changed_records = poller.send(
        :detect_changes,
        @sync_source,
        "base123",
        "tbl123",
        records,
        table,
        email_field,
        loops_fields
      )

      # Should return empty array since no Loops fields exist
      assert_equal 0, changed_records.size, "Should not detect changes when no Loops fields exist"

      # Should not create any baselines
      baselines = FieldValueBaseline.where(sync_source: @sync_source)
      assert_equal 0, baselines.count, "Should not create any baselines when no Loops fields exist"
    end

    test "detect_changes does not create baselines for exact non-Loops fields from user report" do
      # Test using the exact field names from the user's CSV data
      table = {
        "fields" => [
          { "id" => "fldEmail", "name" => "email" },
          { "id" => "fldimgRW3BVDJPULl", "name" => "Loops - lastName" },
          { "id" => "fldA6xic5Me6IxBed", "name" => "Zapier - Added to Midnight Loops list at" },
          { "id" => "fldW9AgGpoU2VHaeP", "name" => "referral_target" },
          { "id" => "fldQzRm5jW3KnzGkk", "name" => "inbound_referrals" },
          { "id" => "fldrLrAoZ0Cz7ZMai", "name" => "number_of_referrals" },
          { "id" => "fldPv2jEDihPvDOuZ", "name" => "Loops - birthday" },
          { "id" => "fldA1EtUNrU2OZiXW", "name" => "Loops - firstName" }
        ]
      }

      email_field = { "id" => "fldEmail", "name" => "email" }

      # Find Loops fields using the actual find_loops_fields logic
      poller = Pollers::AirtableToLoops.new
      loops_fields = poller.send(:find_loops_fields, table)

      # Verify we found only Loops fields
      assert_equal 3, loops_fields.size, "Should find 3 Loops fields"
      assert loops_fields.key?("fldimgRW3BVDJPULl"), "Should include Loops - lastName"
      assert loops_fields.key?("fldPv2jEDihPvDOuZ"), "Should include Loops - birthday"
      assert loops_fields.key?("fldA1EtUNrU2OZiXW"), "Should include Loops - firstName"

      # Create mock record matching user's data
      records = [
        {
          "id" => "recBV0ElVYe4YEFzW",
          "fields" => {
            "email" => "test@example.com",
            "Loops - lastName" => "Sasha",
            "Zapier - Added to Midnight Loops list at" => nil,
            "referral_target" => [ "recBV0ElVYe4YEFzW" ],
            "inbound_referrals" => nil,
            "number_of_referrals" => 0,
            "Loops - birthday" => "2009-04-14",
            "Loops - firstName" => "Colomischi"
          }
        }
      ]

      # Call detect_changes
      changed_records = poller.send(
        :detect_changes,
        @sync_source,
        "base123",
        "tbldJ8CL1xt7qcnrM",
        records,
        table,
        email_field,
        loops_fields
      )

      # Verify only Loops field baselines were created
      baselines = FieldValueBaseline.where(sync_source: @sync_source)
      baseline_field_ids = baselines.pluck(:field_id)

      # Should only have baselines for Loops fields (format: "field_id/field_name")
      assert_equal 3, baselines.count, "Should create 3 baselines (one for each Loops field)"

      assert baseline_field_ids.any? { |id| id.include?("Loops - lastName") },
        "Should have baseline for Loops - lastName"
      assert baseline_field_ids.any? { |id| id.include?("Loops - birthday") },
        "Should have baseline for Loops - birthday"
      assert baseline_field_ids.any? { |id| id.include?("Loops - firstName") },
        "Should have baseline for Loops - firstName"

      # Verify non-Loops fields did NOT create baselines (exact field names from user's CSV)
      assert baseline_field_ids.none? { |id| id.include?("Zapier - Added to Midnight Loops list at") },
        "Should NOT have baseline for Zapier - Added to Midnight Loops list at"
      assert baseline_field_ids.none? { |id| id.include?("referral_target") },
        "Should NOT have baseline for referral_target"
      assert baseline_field_ids.none? { |id| id.include?("inbound_referrals") },
        "Should NOT have baseline for inbound_referrals"
      assert baseline_field_ids.none? { |id| id.include?("number_of_referrals") },
        "Should NOT have baseline for number_of_referrals"
    end

    test "normalizes single-element arrays from Airtable to scalar values" do
      # Test that when Airtable returns ["test"], it's normalized to "test" downstream
      table = {
        "fields" => [
          { "id" => "fldEmail", "name" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - firstName" }
        ]
      }

      email_field = { "id" => "fldEmail", "name" => "email" }
      loops_fields = { "fldLoops1" => { "id" => "fldLoops1", "name" => "Loops - firstName" } }

      # Record with array value (simulating Airtable lookup/rollup returning ["test"])
      records = [
        {
          "id" => "rec123",
          "fields" => {
            "email" => "test@example.com",
            "Loops - firstName" => [ "test" ] # Array value from Airtable
          }
        }
      ]

      poller = Pollers::AirtableToLoops.new

      # Call detect_changes
      changed_records = poller.send(
        :detect_changes,
        @sync_source,
        "base123",
        "tbl123",
        records,
        table,
        email_field,
        loops_fields
      )

      # Verify change was detected
      assert_equal 1, changed_records.size, "Should detect change"
      assert_equal 1, changed_records.first[:changedValues].size, "Should have one changed field"

      # Verify the value in changed_values is normalized to "test" (not ["test"])
      changed_value_data = changed_records.first[:changedValues].values.first
      assert_equal "test", changed_value_data["value"], "Value should be normalized from array to string"
      assert_not_equal [ "test" ], changed_value_data["value"], "Value should not be an array"

      # Verify baseline stores normalized value
      baseline = FieldValueBaseline.where(sync_source: @sync_source).first
      assert_not_nil baseline, "Baseline should be created"
      assert_equal "test", baseline.last_known_value, "Baseline should store normalized value"

      # Verify that if we pass the same normalized value again, it doesn't detect a change
      records2 = [
        {
          "id" => "rec123",
          "fields" => {
            "email" => "test@example.com",
            "Loops - firstName" => "test" # Normalized value
          }
        }
      ]

      changed_records2 = poller.send(
        :detect_changes,
        @sync_source,
        "base123",
        "tbl123",
        records2,
        table,
        email_field,
        loops_fields
      )

      assert_equal 0, changed_records2.size, "Should not detect change when normalized value matches"
    end

    test "triggers full resync when field type changes" do
      table_id = "tbl123"
      base_id = "base123"

      # Mock table with Loops field
      table = {
        "id" => table_id,
        "name" => "Test Table",
        "fields" => [
          { "id" => "fldEmail", "name" => "email", "type" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - firstName", "type" => "multilineText" }
        ]
      }

      email_field = { "id" => "fldEmail", "name" => "email", "type" => "email" }

      # Store initial field type (different from current)
      @sync_source.update_columns(metadata: {
        "known_loops_fields" => {
          table_id => {
            "fldLoops1/Loops - firstName" => "singleLineText"
          }
        }
      })

      poller = Pollers::AirtableToLoops.new

      # Mock fetch_records to track if fetch_all was called
      fetch_all_called = false
      poller.stub :fetch_records, ->(*args, **kwargs) {
        fetch_all_called = kwargs[:fetch_all] || false
        []
      } do
        poller.send(:process_table, @sync_source, base_id, table_id, table)
      end

      # Should trigger full resync (fetch_all should be true)
      assert fetch_all_called, "Should trigger full resync when field type changes"
    end

    test "triggers full resync when new field is added" do
      table_id = "tbl123"
      base_id = "base123"

      # Mock table with one Loops field
      table = {
        "id" => table_id,
        "name" => "Test Table",
        "fields" => [
          { "id" => "fldEmail", "name" => "email", "type" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - firstName", "type" => "singleLineText" }
        ]
      }

      email_field = { "id" => "fldEmail", "name" => "email", "type" => "email" }

      # No existing metadata (no fields tracked yet)
      @sync_source.update_columns(metadata: {})

      poller = Pollers::AirtableToLoops.new

      # Mock fetch_records to track if fetch_all was called
      fetch_all_called = false
      poller.stub :fetch_records, ->(*args, **kwargs) {
        fetch_all_called = kwargs[:fetch_all] || false
        []
      } do
        poller.send(:process_table, @sync_source, base_id, table_id, table)
      end

      # Should trigger full resync for new field
      assert fetch_all_called, "Should trigger full resync when new field is added"
    end

    test "stores field types in metadata" do
      table_id = "tbl123"
      base_id = "base123"

      # Mock table with Loops fields
      table = {
        "id" => table_id,
        "name" => "Test Table",
        "fields" => [
          { "id" => "fldEmail", "name" => "email", "type" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - firstName", "type" => "singleLineText" },
          { "id" => "fldLoops2", "name" => "Loops - lastName", "type" => "email" }
        ]
      }

      email_field = { "id" => "fldEmail", "name" => "email", "type" => "email" }

      @sync_source.update_columns(metadata: {})

      poller = Pollers::AirtableToLoops.new
      poller.stub :fetch_records, [] do
        poller.send(:process_table, @sync_source, base_id, table_id, table)
      end

      # Reload sync_source to get updated metadata
      @sync_source.reload
      metadata = @sync_source.metadata
      known_fields = metadata["known_loops_fields"][table_id]

      # Should be a hash mapping field identifiers to types
      assert_instance_of Hash, known_fields, "Metadata should store field map as hash"
      assert_equal "singleLineText", known_fields["fldLoops1/Loops - firstName"], "Should store firstName field type"
      assert_equal "email", known_fields["fldLoops2/Loops - lastName"], "Should store lastName field type"
    end

    test "does not trigger full resync when field types remain the same" do
      table_id = "tbl123"
      base_id = "base123"

      # Mock table with Loops field
      table = {
        "id" => table_id,
        "name" => "Test Table",
        "fields" => [
          { "id" => "fldEmail", "name" => "email", "type" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - firstName", "type" => "singleLineText" }
        ]
      }

      email_field = { "id" => "fldEmail", "name" => "email", "type" => "email" }

      # Existing metadata with same field type
      @sync_source.update_columns(metadata: {
        "known_loops_fields" => {
          table_id => {
            "fldLoops1/Loops - firstName" => "singleLineText"
          }
        }
      })

      poller = Pollers::AirtableToLoops.new

      # Mock fetch_records to track if fetch_all was called
      fetch_all_called = false
      poller.stub :fetch_records, ->(*args, **kwargs) {
        fetch_all_called = kwargs[:fetch_all] || false
        []
      } do
        poller.send(:process_table, @sync_source, base_id, table_id, table)
      end

      # Should NOT trigger full resync when types are the same
      assert_not fetch_all_called, "Should not trigger full resync when field types remain the same"
    end

    test "triggers full resync when formula field formula changes" do
      table_id = "tbl123"
      base_id = "base123"

      # Mock table with formula field
      table = {
        "id" => table_id,
        "name" => "Test Table",
        "fields" => [
          { "id" => "fldEmail", "name" => "email", "type" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - fullName", "type" => "formula", "options" => { "formula" => "{firstName} & ' ' & {lastName}" } }
        ]
      }

      email_field = { "id" => "fldEmail", "name" => "email", "type" => "email" }

      # Existing metadata with different formula
      @sync_source.update_columns(metadata: {
        "known_loops_fields" => {
          table_id => {
            "fldLoops1/Loops - fullName" => "formula:{firstName} & {lastName}"
          }
        }
      })

      poller = Pollers::AirtableToLoops.new

      # Mock fetch_records to track if fetch_all was called
      fetch_all_called = false
      poller.stub :fetch_records, ->(*args, **kwargs) {
        fetch_all_called = kwargs[:fetch_all] || false
        []
      } do
        poller.send(:process_table, @sync_source, base_id, table_id, table)
      end

      # Should trigger full resync when formula changes
      assert fetch_all_called, "Should trigger full resync when formula changes"
    end

    test "stores formula in metadata for formula fields" do
      table_id = "tbl123"
      base_id = "base123"

      # Mock table with formula field
      table = {
        "id" => table_id,
        "name" => "Test Table",
        "fields" => [
          { "id" => "fldEmail", "name" => "email", "type" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - fullName", "type" => "formula", "options" => { "formula" => "{firstName} & ' ' & {lastName}" } }
        ]
      }

      @sync_source.update_columns(metadata: {})

      poller = Pollers::AirtableToLoops.new
      poller.stub :fetch_records, [] do
        poller.send(:process_table, @sync_source, base_id, table_id, table)
      end

      # Reload sync_source to get updated metadata
      @sync_source.reload
      metadata = @sync_source.metadata
      known_fields = metadata["known_loops_fields"][table_id]

      # Should store formula with "formula:" prefix
      assert_equal "formula:{firstName} & ' ' & {lastName}", known_fields["fldLoops1/Loops - fullName"], "Should store formula text for formula fields"
    end

    test "formula field tracking works end-to-end" do
      table_id = "tbl123"
      base_id = "base123"

      # First run: Process table with formula field
      table1 = {
        "id" => table_id,
        "name" => "Test Table",
        "fields" => [
          { "id" => "fldEmail", "name" => "email", "type" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - fullName", "type" => "formula", "options" => { "formula" => "{firstName} & ' ' & {lastName}" } }
        ]
      }

      @sync_source.update_columns(metadata: {})

      poller = Pollers::AirtableToLoops.new
      poller.stub :fetch_records, [] do
        poller.send(:process_table, @sync_source, base_id, table_id, table1)
      end

      # Verify formula was stored
      @sync_source.reload
      metadata = @sync_source.metadata
      known_fields = metadata["known_loops_fields"][table_id]
      assert_equal "formula:{firstName} & ' ' & {lastName}", known_fields["fldLoops1/Loops - fullName"]

      # Second run: Same formula - should NOT trigger full resync
      fetch_all_called = false
      poller.stub :fetch_records, ->(*args, **kwargs) {
        fetch_all_called = kwargs[:fetch_all] || false
        []
      } do
        poller.send(:process_table, @sync_source, base_id, table_id, table1)
      end

      assert_not fetch_all_called, "Should not trigger full resync when formula is unchanged"

      # Third run: Formula changed - should trigger full resync
      table2 = {
        "id" => table_id,
        "name" => "Test Table",
        "fields" => [
          { "id" => "fldEmail", "name" => "email", "type" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - fullName", "type" => "formula", "options" => { "formula" => "UPPER({firstName} & ' ' & {lastName})" } }
        ]
      }

      fetch_all_called = false
      poller.stub :fetch_records, ->(*args, **kwargs) {
        fetch_all_called = kwargs[:fetch_all] || false
        []
      } do
        poller.send(:process_table, @sync_source, base_id, table_id, table2)
      end

      assert fetch_all_called, "Should trigger full resync when formula changes"

      # Verify new formula was stored
      @sync_source.reload
      metadata = @sync_source.metadata
      known_fields = metadata["known_loops_fields"][table_id]
      assert_equal "formula:UPPER({firstName} & ' ' & {lastName})", known_fields["fldLoops1/Loops - fullName"]
    end

    test "formula and regular fields work together" do
      table_id = "tbl123"
      base_id = "base123"

      table = {
        "id" => table_id,
        "name" => "Test Table",
        "fields" => [
          { "id" => "fldEmail", "name" => "email", "type" => "email" },
          { "id" => "fldLoops1", "name" => "Loops - firstName", "type" => "singleLineText" },
          { "id" => "fldLoops2", "name" => "Loops - fullName", "type" => "formula", "options" => { "formula" => "{firstName} & ' ' & {lastName}" } }
        ]
      }

      @sync_source.update_columns(metadata: {})

      poller = Pollers::AirtableToLoops.new
      poller.stub :fetch_records, [] do
        poller.send(:process_table, @sync_source, base_id, table_id, table)
      end

      @sync_source.reload
      metadata = @sync_source.metadata
      known_fields = metadata["known_loops_fields"][table_id]

      # Should store regular field type
      assert_equal "singleLineText", known_fields["fldLoops1/Loops - firstName"]
      # Should store formula with prefix
      assert_equal "formula:{firstName} & ' ' & {lastName}", known_fields["fldLoops2/Loops - fullName"]
    end

    test "tracks loops_list_fields in metadata and detects type changes" do
      table_id = "tbl123"
      base_id = "base123"

      table = {
        "id" => table_id,
        "name" => "Test Table",
        "fields" => [
          { "id" => "fldEmail", "name" => "email", "type" => "email" },
          { "id" => "fldLoops1", "name" => "Loops List - Test List", "type" => "singleLineText" }
        ]
      }

      @sync_source.update_columns(metadata: {})

      poller = Pollers::AirtableToLoops.new
      poller.stub :fetch_records, [] do
        poller.send(:process_table, @sync_source, base_id, table_id, table)
      end

      # Verify loops_list_field was stored in metadata
      @sync_source.reload
      metadata = @sync_source.metadata
      known_fields = metadata["known_loops_fields"][table_id]
      assert_equal "singleLineText", known_fields["fldLoops1/Loops List - Test List"]

      # Change field type - should trigger full resync
      table2 = {
        "id" => table_id,
        "name" => "Test Table",
        "fields" => [
          { "id" => "fldEmail", "name" => "email", "type" => "email" },
          { "id" => "fldLoops1", "name" => "Loops List - Test List", "type" => "multilineText" }
        ]
      }

      fetch_all_called = false
      poller.stub :fetch_records, ->(*args, **kwargs) {
        fetch_all_called = kwargs[:fetch_all] || false
        []
      } do
        poller.send(:process_table, @sync_source, base_id, table_id, table2)
      end

      assert fetch_all_called, "Should trigger full resync when loops_list_field type changes"
    end
  end
end
