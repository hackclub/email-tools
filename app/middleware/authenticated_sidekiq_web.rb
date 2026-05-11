# Wrapper for Sidekiq::Web that adds HTTP Basic Authentication
class AuthenticatedSidekiqWeb
  def initialize(app = nil)
    @app = app || Sidekiq::Web
  end

  def call(env)
    username = ENV["ADMIN_USERNAME"]
    password = ENV["ADMIN_PASSWORD"]

    # Only require auth if credentials are configured
    if username.present? && password.present?
      auth = Rack::Auth::Basic::Request.new(env)

      unless auth.provided? && auth.basic? && auth.credentials == [ username, password ]
        return [
          401,
          {
            "Content-Type" => "text/plain",
            "WWW-Authenticate" => 'Basic realm="Admin Area"'
          },
          [ "Authentication required" ]
        ]
      end
    end

    # Call the original Sidekiq::Web app
    @app.call(env)
  end
end
