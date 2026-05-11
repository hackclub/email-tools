require "test_helper"

class AdminControllerTest < ActionDispatch::IntegrationTest
  def setup
    @username = "test_admin"
    @password = "test_password"
    ENV["ADMIN_USERNAME"] = @username
    ENV["ADMIN_PASSWORD"] = @password
  end

  def teardown
    ENV.delete("ADMIN_USERNAME")
    ENV.delete("ADMIN_PASSWORD")
  end

  test "should require authentication for admin emails index" do
    get admin_emails_url
    assert_response :unauthorized
  end

  test "should allow access to admin emails with correct credentials" do
    get admin_emails_url, headers: basic_auth_header(@username, @password)
    assert_response :success
  end

  test "should require authentication for admin sync_sources index" do
    get admin_sync_sources_url
    assert_response :unauthorized
  end

  test "should allow access to admin sync_sources with correct credentials" do
    get admin_sync_sources_url, headers: basic_auth_header(@username, @password)
    assert_response :success
  end

  test "should require authentication for admin sidekiq" do
    get "/admin/sidekiq"
    assert_response :unauthorized
  end

  test "should allow access to admin sidekiq with correct credentials" do
    get "/admin/sidekiq", headers: basic_auth_header(@username, @password)
    # Sidekiq might redirect or return different status, but should not be unauthorized
    assert_not_equal 401, response.status
  end

  test "should not require authentication for health check" do
    get "/up"
    assert_response :success
  end

  private

  def basic_auth_header(username, password)
    credentials = ActionController::HttpAuthentication::Basic.encode_credentials(username, password)
    { "HTTP_AUTHORIZATION" => credentials }
  end
end
