# Ensure schematist (schema DSL used by ruby_llm 2.x) is loaded for Sidekiq workers
require "schematist"

RubyLLM.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  # Default model for structured extraction (name / address splitting).
  # gpt-6-luna (low effort) was chosen after a Nov 2026 eval on real prod prompts.
  # Override per-environment with LLM_MODEL; effort with LLM_REASONING_EFFORT.
  config.default_model = ENV.fetch("LLM_MODEL", "gpt-6-luna") # keep in sync with Ai::Client::DEFAULT_MODEL
  # Increase timeout for high reasoning effort calls (contact merging can take several minutes)
  config.request_timeout = ENV.fetch("RUBYLLM_REQUEST_TIMEOUT", 600).to_i # 10 minutes default
end
