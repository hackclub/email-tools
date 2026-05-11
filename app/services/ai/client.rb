require_relative "../../lib/rate_limiter"

module Ai
  class Client
    # Get the global rate limiter (lazy initialization)
    # 100 requests per second
    def self.global_rate_limiter
      @global_rate_limiter ||= RateLimiter.new(
        redis: REDIS_FOR_RATE_LIMITING,
        key: "rate:llm:global",
        limit: 100,
        period: 1.0
      )
    end

    # Generate structured output using RubyLLM
    # @param prompt [String] The prompt to send to the LLM
    # @param schema_class [Class] RubyLLM schema class for structured output
    # @param temp [Float] Temperature for generation (default: 0)
    # @param model [String] Optional model name (defaults to RubyLLM.config.default_model)
    # @param reasoning_effort [String] Optional reasoning effort for GPT-5 models (e.g., "minimal", "high")
    # @return [Hash] Parsed structured data hash
    def self.structured_generate(prompt:, schema_class:, temp: 0, model: nil, reasoning_effort: nil)
      start_time = Time.current

      # Rate limit before making request
      global_rate_limiter.acquire!

      begin
        # Use RubyLLM with structured output
        chat = RubyLLM.chat.with_schema(schema_class)

        # Use provided model or default
        model_to_use = model || RubyLLM.config.default_model

        # Set model if provided
        if model
          chat = chat.with_model(model)
        end

        # Set temperature
        chat = chat.with_temperature(temp)

        # Set reasoning parameters for GPT-5 models
        if model_to_use&.start_with?("gpt-5")
          effort = reasoning_effort || "minimal"
          chat = chat.with_params(reasoning_effort: effort)
        end

        response = chat.ask(prompt)

        latency_ms = ((Time.current - start_time) * 1000).round

        parsed_data = response.content

        Rails.logger.info(
          "Ai::Client.structured_generate: model=#{model_to_use}, " \
          "temp=#{temp}, " \
          "latency_ms=#{latency_ms}, cache=miss"
        )

        parsed_data
      rescue => e
        latency_ms = ((Time.current - start_time) * 1000).round
        Rails.logger.error(
          "Ai::Client.structured_generate failed: error=#{e.class.name}, " \
          "message=#{e.message}, latency_ms=#{latency_ms}"
        )
        raise
      end
    end

    # Generate with caching support
    # @param cache_key [String] Cache key (hash of prompt + schema + temp)
    # @param prompt [String] The prompt to send
    # @param schema_class [Class] RubyLLM schema class
    # @param temp [Float] Temperature (default: 0)
    # @return [Hash] Parsed structured data hash
    def self.get_or_generate(cache_key:, prompt:, schema_class:, temp: 0)
      # Check cache first
      cache_entry = LlmCache.find_by(prompt_hash: cache_key)

      if cache_entry
        cache_entry.touch_last_used!
        Rails.logger.info("Ai::Client.get_or_generate: cache=hit")
        return cache_entry.response_json["parsed"]
      end

      # Cache miss - generate
      parsed_data = structured_generate(
        prompt: prompt,
        schema_class: schema_class,
        temp: temp
      )

      # Store in cache
      request_json = {
        prompt: prompt,
        schema_class: schema_class.name,
        temp: temp
      }

      cache_entry = LlmCache.create!(
        prompt_hash: cache_key,
        request_json: request_json,
        response_json: { parsed: parsed_data },
        bytes_size: 0
      )

      # Bytes size will be calculated by before_save callback
      parsed_data
    end
  end
end
