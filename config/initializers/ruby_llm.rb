# Ensure ruby_llm/schema is loaded for Sidekiq workers
require "ruby_llm/schema"

RubyLLM.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  # Default model for structured extraction (name / address splitting).
  # gpt-5.6-luna was chosen after benchmarking real prod prompts (Sept 2026):
  # it produced better-judged address/name splits than gpt-5 at ~1/6 the cost.
  # Override per-environment with LLM_MODEL; effort with LLM_REASONING_EFFORT.
  config.default_model = ENV.fetch("LLM_MODEL", "gpt-5.6-luna") # keep in sync with Ai::Client::DEFAULT_MODEL
  # Increase timeout for high reasoning effort calls (contact merging can take several minutes)
  config.request_timeout = ENV.fetch("RUBYLLM_REQUEST_TIMEOUT", 600).to_i # 10 minutes default
end
