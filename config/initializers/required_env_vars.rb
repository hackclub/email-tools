# Validate that required environment variables are set
# Skip during asset precompilation (assets don't need these env vars)
def asset_precompilation?
  return true if ENV["RAILS_GROUPS"] == "assets"
  return false unless defined?(Rake)
  begin
    Rake.application&.top_level_tasks&.any? { |task| task.to_s.include?("assets:precompile") } || false
  rescue NoMethodError, NameError
    false
  end
end

skip_validation = Rails.env.test? || asset_precompilation?

unless skip_validation
  required_env_vars = {
    "AIRTABLE_PERSONAL_ACCESS_TOKEN" => ENV["AIRTABLE_PERSONAL_ACCESS_TOKEN"],
    "LOOPS_API_KEY" => ENV["LOOPS_API_KEY"],
    "OPENAI_API_KEY" => ENV["OPENAI_API_KEY"],
    "LOOPS_ALT_UNSUBSCRIBE_RESULTS_TRANSACTIONAL_ID" => ENV["LOOPS_ALT_UNSUBSCRIBE_RESULTS_TRANSACTIONAL_ID"],
    "LOOPS_OTP_TRANSACTIONAL_ID" => ENV["LOOPS_OTP_TRANSACTIONAL_ID"]
  }

  # DATABASE_URL is required in production
  if Rails.env.production?
    required_env_vars["DATABASE_URL"] = ENV["DATABASE_URL"]
  end

  missing_vars = required_env_vars.select { |_key, value| value.blank? }.keys

  if missing_vars.any?
    error_message = "Missing required environment variables: #{missing_vars.join(", ")}\n\n"
    error_message += "Please set the following environment variables:\n"

    missing_vars.each do |var|
      case var
      when "AIRTABLE_PERSONAL_ACCESS_TOKEN"
        error_message += "  - #{var} (Airtable token with access to bases you want to poll)\n"
      when "LOOPS_API_KEY"
        error_message += "  - #{var} (API key for updating Loops contacts)\n"
      when "OPENAI_API_KEY"
        error_message += "  - #{var} (for splitting addresses and full names into individual parts, and for alt unsubscribe contact merging)\n"
      when "LOOPS_ALT_UNSUBSCRIBE_RESULTS_TRANSACTIONAL_ID"
        error_message += "  - #{var} (transactional email ID for sending alt unsubscribe results)\n"
      when "LOOPS_OTP_TRANSACTIONAL_ID"
        error_message += "  - #{var} (transactional email ID for sending OTP codes)\n"
      when "DATABASE_URL"
        error_message += "  - #{var} (PostgreSQL connection URL, e.g., postgresql://user:pass@host:5432/dbname)\n"
      else
        error_message += "  - #{var}\n"
      end
    end

    raise error_message
  end
end
