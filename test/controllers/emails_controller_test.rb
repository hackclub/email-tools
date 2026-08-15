require "test_helper"

class EmailsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @username = "test_admin"
    @password = "test_password"
    ENV["ADMIN_USERNAME"] = @username
    ENV["ADMIN_PASSWORD"] = @password

    LoopsContactChangeAudit.destroy_all
    LoopsEmailActivity.destroy_all
  end

  def teardown
    ENV.delete("ADMIN_USERNAME")
    ENV.delete("ADMIN_PASSWORD")

    LoopsContactChangeAudit.destroy_all
    LoopsEmailActivity.destroy_all
  end

  def auth_headers
    credentials = ActionController::HttpAuthentication::Basic.encode_credentials(@username, @password)
    { "HTTP_AUTHORIZATION" => credentials }
  end

  def seed_activities(count, base_time: Time.parse("2026-08-01T00:00:00Z"))
    now = Time.current
    rows = count.times.map do |i|
      {
        email_normalized: "user#{i}@example.com",
        last_occurred_at: base_time - i.minutes,
        created_at: now,
        updated_at: now
      }
    end
    LoopsEmailActivity.insert_all(rows)
  end

  test "index requires admin auth" do
    get admin_emails_path
    assert_response :unauthorized
  end

  test "index lists emails most recently active first" do
    seed_activities(3)

    get admin_emails_path, headers: auth_headers
    assert_response :success

    body = response.body
    # user0 is most recent, user2 oldest
    assert body.index("user0@example.com") < body.index("user1@example.com")
    assert body.index("user1@example.com") < body.index("user2@example.com")
  end

  test "index paginates at 1000 emails per page" do
    seed_activities(1005)

    get admin_emails_path, headers: auth_headers
    assert_response :success
    assert_includes response.body, "user0@example.com"
    assert_includes response.body, "user999@example.com"
    assert_not_includes response.body, "user1000@example.com"
    assert_includes response.body, "Page 1 of 2"

    get admin_emails_path(page: 2), headers: auth_headers
    assert_response :success
    assert_includes response.body, "user1000@example.com"
    assert_includes response.body, "user1004@example.com"
    assert_not_includes response.body, "user999@example.com"
    assert_includes response.body, "Page 2 of 2"
  end

  test "index clamps out-of-range page numbers" do
    seed_activities(1005)

    # Too-high page clamps to the last page
    get admin_emails_path(page: 99), headers: auth_headers
    assert_response :success
    assert_includes response.body, "Page 2 of 2"
    assert_includes response.body, "user1004@example.com"

    # Zero/negative pages clamp to the first page
    get admin_emails_path(page: 0), headers: auth_headers
    assert_response :success
    assert_includes response.body, "Page 1 of 2"
    assert_includes response.body, "user0@example.com"
  end

  test "index search filters case-insensitively by substring" do
    seed_activities(20)

    get admin_emails_path(q: "USER1@"), headers: auth_headers
    assert_response :success
    assert_includes response.body, "user1@example.com"
    assert_not_includes response.body, "user2@example.com"
    # user1@ should not substring-match user10..user19
    assert_not_includes response.body, "user10@example.com"
  end

  test "index search escapes SQL LIKE wildcards" do
    seed_activities(3)

    get admin_emails_path(q: "%"), headers: auth_headers
    assert_response :success
    assert_not_includes response.body, "user0@example.com"
    assert_includes response.body, "No emails found"
  end

  test "index shows empty state when there are no emails" do
    get admin_emails_path, headers: auth_headers
    assert_response :success
    assert_includes response.body, "No emails with audit logs found"
  end

  test "creating an audit makes its email appear on the index page" do
    LoopsContactChangeAudit.create!(
      email_normalized: "fresh@example.com",
      field_name: "firstName",
      occurred_at: Time.current,
      is_self_service: true
    )

    get admin_emails_path, headers: auth_headers
    assert_response :success
    assert_includes response.body, "fresh@example.com"
  end
end
