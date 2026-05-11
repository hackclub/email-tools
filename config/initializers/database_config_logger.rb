# Log database configuration at boot time for debugging production issues
# This helps diagnose connection problems by showing what Rails sees
if Rails.env.production?
  Rails.logger.info "=== Database Configuration at Rails Boot ==="
  Rails.logger.info "RAILS_ENV: #{Rails.env}"
  Rails.logger.info "DATABASE_URL: #{ENV['DATABASE_URL'].present? ? "set (length: #{ENV['DATABASE_URL'].length})" : "NOT SET"}"

  if ENV["DATABASE_URL"].present?
    begin
      require "uri"
      db_uri = URI.parse(ENV["DATABASE_URL"])
      masked_url = "#{db_uri.scheme}://#{db_uri.user}:***@#{db_uri.host}:#{db_uri.port}#{db_uri.path}"
      Rails.logger.info "DATABASE_URL (masked): #{masked_url}"
    rescue => e
      Rails.logger.warn "Could not parse DATABASE_URL: #{e.message}"
    end
  end

  # Log what Rails sees in database.yml
  begin
    db_config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: :primary)
    if db_config
      config_hash = db_config.configuration_hash
      Rails.logger.info "Database config host: #{config_hash[:host] || 'not set'}"
      Rails.logger.info "Database config port: #{config_hash[:port] || 'not set'}"
      Rails.logger.info "Database config database: #{config_hash[:database] || 'not set'}"
      Rails.logger.info "Database config adapter: #{config_hash[:adapter] || 'not set'}"
      Rails.logger.info "Database config url present: #{config_hash[:url].present?}"
    else
      Rails.logger.warn "No database config found for #{Rails.env} environment"
    end
  rescue => e
    Rails.logger.error "Error reading database config: #{e.message}"
    Rails.logger.error e.backtrace.first(5).join("\n")
  end

  Rails.logger.info "REDIS_URL: #{ENV['REDIS_URL'].present? ? 'set' : 'NOT SET'}"
  Rails.logger.info "DB_POOL_SIZE: #{ENV['DB_POOL_SIZE'] || 'not set'}"
  Rails.logger.info "RAILS_MAX_THREADS: #{ENV['RAILS_MAX_THREADS'] || 'not set'}"
  Rails.logger.info "============================================="
end
