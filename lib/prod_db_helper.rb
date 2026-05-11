# Helper module to easily access production readonly database
# Usage in Rails runner:
#   rails runner "ProdDbHelper.with_prod { puts LoopsOutboxEnvelope.count }"
#   rails runner "ProdDbHelper.with_prod { puts LoopsOutboxEnvelope.where(status: :failed).count }"
module ProdDbHelper
  def self.with_prod(&block)
    unless ENV["PROD_READONLY_DATABASE_URL"]
      raise "PROD_READONLY_DATABASE_URL environment variable not set"
    end

    # Try to get config from database.yml first
    configs = ActiveRecord::Base.configurations.configs_for(env_name: "production", name: "production_readonly")
    prod_config = configs&.first

    unless prod_config
      # Fallback: create config hash directly from URL
      prod_config_hash = {
        adapter: "postgresql",
        url: ENV["PROD_READONLY_DATABASE_URL"],
        replica: true
      }
      ActiveRecord::Base.establish_connection(prod_config_hash)
    else
      # Use config from database.yml
      ActiveRecord::Base.establish_connection(prod_config.configuration_hash)
    end

    begin
      # Verify connection works
      ActiveRecord::Base.connection.execute("SELECT 1")

      # Yield to the block
      yield
    ensure
      # Always restore the original connection
      ActiveRecord::Base.establish_connection(:development)
    end
  end

  # Quick access to production models
  def self.prod_connection
    unless ENV["PROD_READONLY_DATABASE_URL"]
      raise "PROD_READONLY_DATABASE_URL environment variable not set"
    end

    prod_config = ActiveRecord::Base.configurations.configs_for(env_name: "production", name: "production_readonly").first
    raise "production_readonly database configuration not found" unless prod_config

    ActiveRecord::Base.establish_connection(prod_config.configuration_hash)
    ActiveRecord::Base.connection
  end
end
