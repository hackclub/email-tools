# Ensure ruby_llm/schema is loaded for Sidekiq workers
require "ruby_llm/schema"

RubyLLM.configure do |config|
  config.openai_api_key = ENV["OPENAI_API_KEY"]
  config.default_model = ENV.fetch("LLM_MODEL", "gpt-5")
  # Increase timeout for GPT-5 with high reasoning effort (can take several minutes)
  config.request_timeout = ENV.fetch("RUBYLLM_REQUEST_TIMEOUT", 600).to_i # 10 minutes default
end
