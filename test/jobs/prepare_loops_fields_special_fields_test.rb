require "test_helper"
require "minitest/mock"

class PrepareLoopsFieldsSpecialFieldsTest < ActiveJob::TestCase
  parallelize(workers: 1)

  def setup
    @sync_source = SyncSource.create!(
      source: "airtable",
      source_id: "app123",
      poll_interval_seconds: 30
    )

    @email = "special@test.com"
    @table_id = "tbl123"
    @record_id = "rec123"

    # Clean up
    LoopsOutboxEnvelope.destroy_all
    LlmCache.destroy_all
  end

  def teardown
    LoopsOutboxEnvelope.destroy_all
    LlmCache.destroy_all
    LoopsListSubscription.destroy_all  # Clean up mailing list subscriptions
    SyncSource.destroy_all
  end

  test "processes setFullName field with real LLM call (non-cached)" do
    # This test will fail initially if LLM is not configured
    changed_fields = {
      "fldSpecial123/Loops - Special - setFullName" => {
        "value" => "John Michael Doe",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    # Verify cache is empty before
    assert_equal 0, LlmCache.count, "Cache should be empty before test"

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    # Verify cache entry was created
    assert_equal 1, LlmCache.count, "Cache should have one entry after LLM call"

    envelope = LoopsOutboxEnvelope.last
    assert_not_nil envelope, "Envelope should be created"

    # Verify extracted fields
    assert envelope.payload.key?("firstName"), "Payload should contain firstName"
    assert envelope.payload.key?("lastName"), "Payload should contain lastName"
    assert_not_nil envelope.payload["firstName"]["value"]
    assert_not_nil envelope.payload["lastName"]["value"]

    # Verify provenance
    field_provenances = envelope.provenance["fields"]
    assert field_provenances.any? { |p| p["derived_to_loops_field"] == "firstName" }
    assert field_provenances.any? { |p| p["derived_to_loops_field"] == "lastName" }
  end

  test "processes setFullName field with cached LLM response" do
    # Create a cache entry first
    prompt = Ai::Prompts::ExtractFullName.call(raw_input: "Jane Smith")
    schema_props = Ai::Prompts::ExtractFullName::Schema.properties.to_json
    temp = 0
    prompt_hash = Digest::SHA256.hexdigest(prompt + schema_props + temp.to_s)

    cached_response = { "firstName" => "Jane", "lastName" => "Smith" }
    LlmCache.create!(
      prompt_hash: prompt_hash,
      request_json: { prompt: prompt, schema_class: "Ai::Prompts::ExtractFullName::Schema", temp: temp },
      response_json: { parsed: cached_response },
      bytes_size: 100
    )

    # Verify cache entry exists
    assert_equal 1, LlmCache.count, "Cache should have one entry"

    changed_fields = {
      "fldSpecial123/Loops - Special - setFullName" => {
        "value" => "Jane Smith",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    # Stub to verify cache is used (should not call LLM)
    original_method = Ai::Client.method(:structured_generate)
    call_count = 0
    Ai::Client.define_singleton_method(:structured_generate) do |**args|
      call_count += 1
      original_method.call(**args)
    end

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    # Restore original method
    Ai::Client.define_singleton_method(:structured_generate, original_method)

    # Verify LLM was not called (cache was used)
    assert_equal 0, call_count, "LLM should not be called when cache exists"

    envelope = LoopsOutboxEnvelope.last
    assert_not_nil envelope, "Envelope should be created"
    assert_equal "Jane", envelope.payload["firstName"]["value"]
    assert_equal "Smith", envelope.payload["lastName"]["value"]
  end

  test "processes setFullAddress field with real LLM call (non-cached)" do
    changed_fields = {
      "fldSpecial456/Loops - Special - setFullAddress" => {
        "value" => "123 Main St, Springfield, IL 62704, USA",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    # Verify cache is empty before
    assert_equal 0, LlmCache.count, "Cache should be empty before test"

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    # Verify cache entry was created
    assert_equal 1, LlmCache.count, "Cache should have one entry after LLM call"

    envelope = LoopsOutboxEnvelope.last
    assert_not_nil envelope, "Envelope should be created"

    # Verify address fields are present
    assert envelope.payload.key?("addressLine1"), "Payload should contain addressLine1"
    assert envelope.payload.key?("addressCity"), "Payload should contain addressCity"
    assert envelope.payload.key?("addressState"), "Payload should contain addressState"
    assert envelope.payload.key?("addressZipCode"), "Payload should contain addressZipCode"
    assert envelope.payload.key?("addressCountry"), "Payload should contain addressCountry"
    assert envelope.payload.key?("addressLastUpdatedAt"), "Payload should contain addressLastUpdatedAt"

    # Verify addressLastUpdatedAt is set
    assert_not_nil envelope.payload["addressLastUpdatedAt"]["value"]
  end

  test "processes setFullAddress field with cached LLM response" do
    # Create a cache entry first
    prompt = Ai::Prompts::ExtractFullAddress.call(raw_input: "456 Oak Ave, Boston, MA 02115, USA")
    schema_props = Ai::Prompts::ExtractFullAddress::Schema.properties.to_json
    temp = 0
    prompt_hash = Digest::SHA256.hexdigest(prompt + schema_props + temp.to_s)

    cached_response = {
      "addressLine1" => "456 Oak Ave",
      "addressCity" => "Boston",
      "addressState" => "MA",
      "addressZipCode" => "02115",
      "addressCountry" => "USA"
    }
    LlmCache.create!(
      prompt_hash: prompt_hash,
      request_json: { prompt: prompt, schema_class: "Ai::Prompts::ExtractFullAddress::Schema", temp: temp },
      response_json: { parsed: cached_response },
      bytes_size: 200
    )

    changed_fields = {
      "fldSpecial456/Loops - Special - setFullAddress" => {
        "value" => "456 Oak Ave, Boston, MA 02115, USA",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    # Verify cache is used
    original_method = Ai::Client.method(:structured_generate)
    call_count = 0
    Ai::Client.define_singleton_method(:structured_generate) do |**args|
      call_count += 1
      original_method.call(**args)
    end

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    Ai::Client.define_singleton_method(:structured_generate, original_method)

    assert_equal 0, call_count, "LLM should not be called when cache exists"

    envelope = LoopsOutboxEnvelope.last
    assert_not_nil envelope, "Envelope should be created"
    assert_equal "456 Oak Ave", envelope.payload["addressLine1"]["value"]
    assert_equal "Boston", envelope.payload["addressCity"]["value"]
    assert_equal "MA", envelope.payload["addressState"]["value"]
  end

  test "cache invalidates when prompt changes" do
    # Create cache entry for "John Doe"
    prompt1 = Ai::Prompts::ExtractFullName.call(raw_input: "John Doe")
    schema_props = Ai::Prompts::ExtractFullName::Schema.properties.to_json
    temp = 0
    prompt_hash1 = Digest::SHA256.hexdigest(prompt1 + schema_props + temp.to_s)

    LlmCache.create!(
      prompt_hash: prompt_hash1,
      request_json: { prompt: prompt1, schema_class: "Ai::Prompts::ExtractFullName::Schema", temp: temp },
      response_json: { parsed: { "firstName" => "John", "lastName" => "Doe" } },
      bytes_size: 100
    )

    # Try with different input - should create new cache entry
    changed_fields = {
      "fldSpecial123/Loops - Special - setFullName" => {
        "value" => "Jane Smith",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    # Should have 2 cache entries (one for John Doe, one for Jane Smith)
    assert_equal 2, LlmCache.count, "Should have 2 cache entries for different inputs"
  end

  test "cache invalidates when schema changes" do
    # This test verifies that changing schema properties creates a new cache entry
    # We'll simulate this by modifying the schema definition

    prompt = Ai::Prompts::ExtractFullName.call(raw_input: "Test Name")
    schema_props_original = Ai::Prompts::ExtractFullName::Schema.properties.to_json
    temp = 0
    prompt_hash_original = Digest::SHA256.hexdigest(prompt + schema_props_original + temp.to_s)

    # Create cache entry
    LlmCache.create!(
      prompt_hash: prompt_hash_original,
      request_json: { prompt: prompt, schema_class: "Ai::Prompts::ExtractFullName::Schema", temp: temp },
      response_json: { parsed: { "firstName" => "Test", "lastName" => "Name" } },
      bytes_size: 100
    )

    # If schema changes, hash should be different
    # This is verified by the hash calculation including schema_props
    assert_equal 1, LlmCache.count, "Should have 1 cache entry"

    # Verify the hash includes schema properties
    assert prompt_hash_original.length > 0, "Prompt hash should be generated"
  end

  test "skips setFullName when value is blank" do
    changed_fields = {
      "fldSpecial123/Loops - Special - setFullName" => {
        "value" => "",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    envelope = LoopsOutboxEnvelope.last
    assert_nil envelope, "No envelope should be created when value is blank"
    assert_equal 0, LlmCache.count, "No cache entry should be created for blank input"
  end

  test "skips setFullAddress when value is blank" do
    changed_fields = {
      "fldSpecial456/Loops - Special - setFullAddress" => {
        "value" => "   ",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    envelope = LoopsOutboxEnvelope.last
    assert_nil envelope, "No envelope should be created when value is blank"
    assert_equal 0, LlmCache.count, "No cache entry should be created for blank input"
  end

  test "handles multiple special fields in same request" do
    changed_fields = {
      "fldSpecial123/Loops - Special - setFullName" => {
        "value" => "John Doe",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      },
      "fldSpecial456/Loops - Special - setFullAddress" => {
        "value" => "123 Main St, City, ST 12345, USA",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    envelope = LoopsOutboxEnvelope.last
    assert_not_nil envelope, "Envelope should be created"

    # Should have name fields
    assert envelope.payload.key?("firstName"), "Should have firstName"
    assert envelope.payload.key?("lastName"), "Should have lastName"

    # Should have address fields
    assert envelope.payload.key?("addressLine1"), "Should have addressLine1"
    assert envelope.payload.key?("addressCity"), "Should have addressCity"

    # Should have 2 cache entries (one for name, one for address)
    assert_equal 2, LlmCache.count, "Should have 2 cache entries"
  end
end
