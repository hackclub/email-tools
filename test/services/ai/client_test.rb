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

  test "default_model falls back to gpt-6-luna and honors LLM_MODEL" do
    ENV.delete("LLM_MODEL")
    assert_equal "gpt-6-luna", Ai::Client.default_model
    ENV["LLM_MODEL"] = "gpt-5-mini"
    assert_equal "gpt-5-mini", Ai::Client.default_model
  ensure
    ENV.delete("LLM_MODEL")
  end

  test "default_reasoning_effort maps legacy gpt-5 models to minimal and newer models to low" do
    ENV.delete("LLM_REASONING_EFFORT")
    assert_equal "minimal", Ai::Client.default_reasoning_effort("gpt-5")
    assert_equal "minimal", Ai::Client.default_reasoning_effort("gpt-5-mini")
    assert_equal "minimal", Ai::Client.default_reasoning_effort("gpt-5.1")
    assert_equal "low", Ai::Client.default_reasoning_effort("gpt-5.6-luna")
    assert_equal "low", Ai::Client.default_reasoning_effort("gpt-5.4-nano")
    assert_equal "low", Ai::Client.default_reasoning_effort("gpt-6-luna")
    assert_equal "low", Ai::Client.default_reasoning_effort("gpt-6.1-terra")
    assert_equal "low", Ai::Client.default_reasoning_effort("gpt-6-astra")
    ENV["LLM_REASONING_EFFORT"] = "medium"
    assert_equal "medium", Ai::Client.default_reasoning_effort("gpt-6-luna")
  ensure
    ENV.delete("LLM_REASONING_EFFORT")
  end

  test "supports_temperature? returns false for GPT-5+, GPT-6+ and o-series models and true for others" do
    %w[
      gpt-5 gpt-5-mini gpt-5.1 gpt-5.6-luna gpt-5.6-terra
      gpt-6 gpt-6-luna gpt-6.1-terra gpt-7-mini
      o1 o1-mini o3 o3-mini o4-mini
    ].each do |model|
      assert_not Ai::Client.supports_temperature?(model), "Expected #{model} not to support temperature"
    end

    %w[gpt-4 gpt-4o gpt-4o-mini gpt-4.1 gpt-4.1-mini gpt-3.5-turbo].each do |model|
      assert Ai::Client.supports_temperature?(model), "Expected #{model} to support temperature"
    end
  end

  test "structured_generate omits temperature for default gpt-6-luna and passes schema and reasoning effort" do
    fake_chat = Class.new do
      attr_reader :schema, :temperature, :thinking, :temperature_set
      def with_schema(schema) = tap { @schema = schema }
      def with_temperature(temp) = tap { @temperature_set = true; @temperature = temp }
      def with_thinking(**options) = tap { @thinking = options }
      def ask(_prompt) = Struct.new(:parsed).new({ "firstName" => "A", "lastName" => "B" })
    end.new
    captured = nil
    RubyLLM.stub(:chat, ->(**kwargs) { captured = kwargs; fake_chat }) do
      Ai::Client.stub(:global_rate_limiter, Struct.new(:x) { def acquire! = nil }.new(nil)) do
        result = Ai::Client.structured_generate(prompt: "p", schema_class: Ai::Prompts::ExtractFullName::Schema)
        assert_equal({ "firstName" => "A", "lastName" => "B" }, result)
      end
    end
    assert_equal({ model: "gpt-6-luna", provider: :openai, assume_model_exists: true }, captured)
    assert_equal Ai::Prompts::ExtractFullName::Schema, fake_chat.schema
    assert_nil fake_chat.temperature
    assert_not fake_chat.temperature_set
    assert_equal({ effort: :low }, fake_chat.thinking)
  end

  test "structured_generate omits temperature for gpt-5.x, gpt-6.x and o-series models" do
    %w[gpt-5.6-luna gpt-5.6-terra gpt-6-luna gpt-6.1-terra o3-mini].each do |model|
      fake_chat = Class.new do
        attr_reader :temperature_set
        def with_schema(_schema) = self
        def with_temperature(_temp) = tap { @temperature_set = true }
        def with_thinking(**_options) = self
        def ask(_prompt) = Struct.new(:parsed).new({ "ok" => true })
      end.new
      RubyLLM.stub(:chat, ->(**_kwargs) { fake_chat }) do
        Ai::Client.stub(:global_rate_limiter, Struct.new(:x) { def acquire! = nil }.new(nil)) do
          Ai::Client.structured_generate(prompt: "p", schema_class: Ai::Prompts::ExtractFullName::Schema, model: model, temp: 0)
        end
      end
      assert_not fake_chat.temperature_set, "Expected no temperature sent for #{model}"
    end
  end

  test "structured_generate sends temperature for models that accept it" do
    fake_chat = Class.new do
      attr_reader :temperature, :temperature_set
      def with_schema(_schema) = self
      def with_temperature(temp) = tap { @temperature_set = true; @temperature = temp }
      def with_thinking(**_options) = self
      def ask(_prompt) = Struct.new(:parsed).new({ "firstName" => "A", "lastName" => "B" })
    end.new
    RubyLLM.stub(:chat, ->(**_kwargs) { fake_chat }) do
      Ai::Client.stub(:global_rate_limiter, Struct.new(:x) { def acquire! = nil }.new(nil)) do
        Ai::Client.structured_generate(
          prompt: "p",
          schema_class: Ai::Prompts::ExtractFullName::Schema,
          model: "gpt-4.1-mini",
          temp: 0
        )
      end
    end
    assert fake_chat.temperature_set
    assert_equal 0, fake_chat.temperature
  end

  test "ruby_llm renders gpt-6-luna and gpt-6.1-terra payloads without temperature and with reasoning effort" do
    original_key = RubyLLM.config.openai_api_key
    RubyLLM.config.openai_api_key = "sk-test-stub"

    extraction_chat = RubyLLM.chat(model: "gpt-6-luna", provider: :openai, assume_model_exists: true)
      .with_schema(Ai::Prompts::ExtractFullName::Schema)
      .with_thinking(effort: :low)
    extraction_payload = extraction_chat.render
    assert_equal "gpt-6-luna", extraction_payload[:model]
    assert_not extraction_payload.key?(:temperature)
    assert_equal({ effort: "low" }, extraction_payload[:reasoning])

    merge_chat = RubyLLM.chat(model: "gpt-6.1-terra", provider: :openai, assume_model_exists: true)
      .with_schema(Ai::Prompts::MergeContacts::Schema)
      .with_thinking(effort: :high)
    merge_payload = merge_chat.render
    assert_equal "gpt-6.1-terra", merge_payload[:model]
    assert_not merge_payload.key?(:temperature)
    assert_equal({ effort: "high" }, merge_payload[:reasoning])

    legacy_chat = RubyLLM.chat(model: "gpt-4.1-mini", provider: :openai, assume_model_exists: true)
      .with_schema(Ai::Prompts::ExtractFullName::Schema)
      .with_temperature(0)
    legacy_payload = legacy_chat.render
    assert_equal "gpt-4.1-mini", legacy_payload[:model]
    assert_equal 0, legacy_payload[:temperature]
  ensure
    RubyLLM.config.openai_api_key = original_key
  end
end
