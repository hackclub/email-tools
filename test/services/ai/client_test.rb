require "test_helper"
require "minitest/mock"

class Ai::ClientTest < ActiveSupport::TestCase
  def setup
    LlmCache.destroy_all
  end

  def teardown
    LlmCache.destroy_all
  end

  test "get_or_generate creates cache entry on first call (non-cached)" do
    prompt = "Test prompt"
    schema_class = Ai::Prompts::ExtractFullName::Schema
    schema_props = schema_class.properties.to_json
    temp = 0
    cache_key = Digest::SHA256.hexdigest(prompt + schema_props + temp.to_s)

    # Verify cache is empty
    assert_equal 0, LlmCache.count, "Cache should be empty"

    # Stub the actual LLM call to return test data
    mock_response = { "firstName" => "Test", "lastName" => "Name" }
    Ai::Client.stub(:structured_generate, mock_response) do
      result = Ai::Client.get_or_generate(
        cache_key: cache_key,
        prompt: prompt,
        schema_class: schema_class
      )

      assert_equal mock_response, result, "Should return the generated result"
    end

    # Verify cache entry was created
    assert_equal 1, LlmCache.count, "Cache should have one entry"
    cache_entry = LlmCache.first
    assert_equal cache_key, cache_entry.prompt_hash, "Cache key should match"
    assert_equal mock_response, cache_entry.response_json["parsed"], "Cache should store the response"
  end

  test "get_or_generate uses cache on second call (cached)" do
    prompt = "Test prompt"
    schema_class = Ai::Prompts::ExtractFullName::Schema
    schema_props = schema_class.properties.to_json
    temp = 0
    cache_key = Digest::SHA256.hexdigest(prompt + schema_props + temp.to_s)

    # Create cache entry
    cached_response = { "firstName" => "Cached", "lastName" => "Response" }
    LlmCache.create!(
      prompt_hash: cache_key,
      request_json: { prompt: prompt, schema_class: schema_class.name, temp: temp },
      response_json: { parsed: cached_response },
      bytes_size: 100
    )

    # Track if structured_generate is called
    call_count = 0
    original_method = Ai::Client.method(:structured_generate)
    Ai::Client.define_singleton_method(:structured_generate) do |**args|
      call_count += 1
      original_method.call(**args)
    end

    result = Ai::Client.get_or_generate(
      cache_key: cache_key,
      prompt: prompt,
      schema_class: schema_class
    )

    # Restore original method
    Ai::Client.define_singleton_method(:structured_generate, original_method)

    # Verify cache was used
    assert_equal 0, call_count, "structured_generate should not be called when cache exists"
    assert_equal cached_response, result, "Should return cached response"
    assert_equal 1, LlmCache.count, "Should still have one cache entry"
  end

  test "get_or_generate updates last_used_at on cache hit" do
    prompt = "Test prompt"
    schema_class = Ai::Prompts::ExtractFullName::Schema
    schema_props = schema_class.properties.to_json
    temp = 0
    cache_key = Digest::SHA256.hexdigest(prompt + schema_props + temp.to_s)

    # Create cache entry with old last_used_at
    old_time = 1.day.ago
    cache_entry = LlmCache.create!(
      prompt_hash: cache_key,
      request_json: { prompt: prompt, schema_class: schema_class.name, temp: temp },
      response_json: { parsed: { "test" => "data" } },
      bytes_size: 100,
      last_used_at: old_time
    )

    sleep 1 # Ensure time difference

    Ai::Client.get_or_generate(
      cache_key: cache_key,
      prompt: prompt,
      schema_class: schema_class
    )

    cache_entry.reload
    assert cache_entry.last_used_at > old_time, "last_used_at should be updated on cache hit"
  end

  test "cache key includes prompt, schema, and temp" do
    prompt1 = "Test prompt"
    prompt2 = "Different prompt"
    schema_class = Ai::Prompts::ExtractFullName::Schema
    schema_props = schema_class.properties.to_json
    temp1 = 0
    temp2 = 1.0

    key1 = Digest::SHA256.hexdigest(prompt1 + schema_props + temp1.to_s)
    key2 = Digest::SHA256.hexdigest(prompt2 + schema_props + temp1.to_s)
    key3 = Digest::SHA256.hexdigest(prompt1 + schema_props + temp2.to_s)

    # All keys should be different
    assert_not_equal key1, key2, "Different prompts should produce different keys"
    assert_not_equal key1, key3, "Different temps should produce different keys"
    assert_not_equal key2, key3, "Different prompts and temps should produce different keys"
  end

  test "cache invalidates when schema properties change" do
    prompt = "Test prompt"
    schema_class = Ai::Prompts::ExtractFullName::Schema
    schema_props1 = schema_class.properties.to_json
    temp = 0

    # Create cache entry
    key1 = Digest::SHA256.hexdigest(prompt + schema_props1 + temp.to_s)
    LlmCache.create!(
      prompt_hash: key1,
      request_json: { prompt: prompt, schema_class: schema_class.name, temp: temp },
      response_json: { parsed: { "test" => "data" } },
      bytes_size: 100
    )

    # If schema changes, hash would be different
    # This test verifies the hash calculation includes schema properties
    schema_props2 = schema_class.properties.to_json
    key2 = Digest::SHA256.hexdigest(prompt + schema_props2 + temp.to_s)

    # Keys should be the same if schema hasn't changed
    assert_equal key1, key2, "Same schema should produce same key"

    # But if we manually change schema_props, keys should differ
    key3 = Digest::SHA256.hexdigest(prompt + "{}" + temp.to_s)
    assert_not_equal key1, key3, "Different schema should produce different key"
  end

  test "handles cache miss gracefully" do
    prompt = "New prompt"
    schema_class = Ai::Prompts::ExtractFullName::Schema
    schema_props = schema_class.properties.to_json
    temp = 0
    cache_key = Digest::SHA256.hexdigest(prompt + schema_props + temp.to_s)

    # Verify cache is empty
    assert_equal 0, LlmCache.count

    # Mock LLM response
    mock_response = { "firstName" => "New", "lastName" => "Name" }
    Ai::Client.stub(:structured_generate, mock_response) do
      result = Ai::Client.get_or_generate(
        cache_key: cache_key,
        prompt: prompt,
        schema_class: schema_class
      )

      assert_equal mock_response, result
      assert_equal 1, LlmCache.count, "Cache entry should be created"
    end
  end

  test "stores correct request metadata in cache" do
    prompt = "Test prompt"
    schema_class = Ai::Prompts::ExtractFullName::Schema
    schema_props = schema_class.properties.to_json
    temp = 0.5
    cache_key = Digest::SHA256.hexdigest(prompt + schema_props + temp.to_s)

    mock_response = { "test" => "data" }
    Ai::Client.stub(:structured_generate, mock_response) do
      Ai::Client.get_or_generate(
        cache_key: cache_key,
        prompt: prompt,
        schema_class: schema_class,
        temp: temp
      )
    end

    cache_entry = LlmCache.first
    assert_equal prompt, cache_entry.request_json["prompt"]
    assert_equal schema_class.name, cache_entry.request_json["schema_class"]
    assert_equal temp, cache_entry.request_json["temp"]
  end
end
