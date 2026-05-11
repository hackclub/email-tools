require "test_helper"
require "minitest/mock"

module Discovery
  class AirtableAdapterTest < ActiveSupport::TestCase
    def setup
      @adapter = AirtableAdapter.new
    end

    test "list_ids_with_names returns array of hashes with id and name" do
      # Mock AirtableService::Bases.find_each
      bases = [
        { "id" => "base1", "name" => "Base One" },
        { "id" => "base2", "name" => "Base Two" }
      ]

      AirtableService::Bases.stub :find_each, ->(&block) { bases.each(&block) } do
        result = @adapter.list_ids_with_names
        assert_equal 2, result.size
        assert_equal "base1", result[0][:id]
        assert_equal "Base One", result[0][:name]
        assert_equal "base2", result[1][:id]
        assert_equal "Base Two", result[1][:name]
      end
    end

    test "list_ids_with_names uses source_id as name when name is nil" do
      bases = [
        { "id" => "base1", "name" => nil }
      ]

      AirtableService::Bases.stub :find_each, ->(&block) { bases.each(&block) } do
        result = @adapter.list_ids_with_names
        assert_equal 1, result.size
        assert_equal "base1", result[0][:id]
        assert_equal "base1", result[0][:name]
      end
    end

    test "list_ids_with_names handles errors gracefully" do
      AirtableService::Bases.stub :find_each, -> { raise StandardError, "API Error" } do
        result = @adapter.list_ids_with_names
        assert_equal [], result
      end
    end

    test "list_ids_with_names returns empty array when no bases found" do
      AirtableService::Bases.stub :find_each, ->(&block) { [].each(&block) } do
        result = @adapter.list_ids_with_names
        assert_equal [], result
      end
    end
  end
end
