require "test_helper"
require "minitest/mock"

module Pollers
  class AirtableToLoopsMailingListTest < ActiveSupport::TestCase
    def setup
      @sync_source = AirtableSyncSource.create!(
        source: "airtable",
        source_id: "app123",
        poll_interval_seconds: 30
      )
      @poller = Pollers::AirtableToLoops.new
    end

    def teardown
      AirtableSyncSource.destroy_all
      LoopsOutboxEnvelope.destroy_all
      FieldValueBaseline.destroy_all
    end

    test "find_loops_list_fields detects Loops List fields" do
      table = {
        "fields" => [
          { "id" => "fld1", "name" => "Email", "type" => "email" },
          { "id" => "fld2", "name" => "Loops List - Any Notes", "type" => "singleLineText" },
          { "id" => "fld3", "name" => "Loops List - 3 Cool Things", "type" => "singleLineText" },
          { "id" => "fld4", "name" => "Loops - tmpField", "type" => "singleLineText" },
          { "id" => "fld5", "name" => "Loops List - Blueprint", "type" => "singleLineText" }
        ]
      }

      result = @poller.send(:find_loops_fields, table)

      # Should include both regular Loops fields and Loops List fields
      assert result.key?("fld2"), "Should detect Loops List field"
      assert result.key?("fld3"), "Should detect Loops List field"
      assert result.key?("fld5"), "Should detect Loops List field"
      assert result.key?("fld4"), "Should detect regular Loops field"
      assert_not result.key?("fld1"), "Should not include email field"
    end

    test "find_loops_list_fields handles case insensitive matching" do
      table = {
        "fields" => [
          { "id" => "fld1", "name" => "Loops list - Test", "type" => "singleLineText" },
          { "id" => "fld2", "name" => "LOOPS LIST - TEST", "type" => "singleLineText" },
          { "id" => "fld3", "name" => "loops list - test", "type" => "singleLineText" }
        ]
      }

      result = @poller.send(:find_loops_fields, table)

      assert_equal 3, result.size, "Should detect all case variations"
    end
  end
end
