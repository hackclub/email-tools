require "test_helper"
require "securerandom"

class AirtableServiceSchemaCacheTest < ActiveSupport::TestCase
  def setup
    @base_id = "appTest#{SecureRandom.hex(6)}"
    @schema_response = {
      "tables" => [
        { "id" => "tbl1", "name" => "Table One", "fields" => [ { "id" => "fld1", "name" => "email" } ] }
      ]
    }
    clear_cache
  end

  def teardown
    clear_cache
    restore_get
  end

  test "get_schema caches the schema and skips the API on subsequent calls" do
    calls = stub_get_counting

    first = AirtableService::Bases.get_schema(base_id: @base_id)
    second = AirtableService::Bases.get_schema(base_id: @base_id)

    assert_equal 1, calls[:count], "Second get_schema should be served from cache"
    assert_equal first, second
    assert_equal "Table One", second["tbl1"]["name"]
  end

  test "get_schema with fresh true bypasses and refreshes the cache" do
    calls = stub_get_counting

    AirtableService::Bases.get_schema(base_id: @base_id)
    AirtableService::Bases.get_schema(base_id: @base_id, fresh: true)

    assert_equal 2, calls[:count], "fresh: true should hit the API"

    AirtableService::Bases.get_schema(base_id: @base_id)
    assert_equal 2, calls[:count], "fresh fetch should re-populate the cache"
  end

  test "invalidate_schema_cache forces the next call to refetch" do
    calls = stub_get_counting

    AirtableService::Bases.get_schema(base_id: @base_id)
    AirtableService::Bases.invalidate_schema_cache(base_id: @base_id)
    AirtableService::Bases.get_schema(base_id: @base_id)

    assert_equal 2, calls[:count], "Invalidated cache should not serve stale schema"
  end

  test "visible field ids variant is cached separately" do
    calls = stub_get_counting

    AirtableService::Bases.get_schema(base_id: @base_id)
    AirtableService::Bases.get_schema(base_id: @base_id, include_visible_field_ids: true)

    assert_equal 2, calls[:count], "Variant with visibleFieldIds must not share the plain cache entry"
  end

  private

  def stub_get_counting
    calls = { count: 0 }
    response = @schema_response
    @original_get = AirtableService.method(:get)
    AirtableService.define_singleton_method(:get) do |_url|
      calls[:count] += 1
      response
    end
    calls
  end

  def restore_get
    AirtableService.define_singleton_method(:get, @original_get) if @original_get
    @original_get = nil
  end

  def clear_cache
    AirtableService::Bases.invalidate_schema_cache(base_id: @base_id)
  end
end
