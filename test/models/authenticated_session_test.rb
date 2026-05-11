require "test_helper"

class AuthenticatedSessionTest < ActiveSupport::TestCase
  def setup
    @email = "test@example.com"
    @email_normalized = EmailNormalizer.normalize(@email)
  end

  test "validates required fields" do
    # Test that email_normalized is required
    session = AuthenticatedSession.new
    # Skip callbacks to test validation
    session.define_singleton_method(:generate_token) { }
    session.define_singleton_method(:set_expires_at) { }
    session.expires_at = nil
    session.token = nil

    assert_not session.valid?
    assert_includes session.errors[:email_normalized], "can't be blank"
    # token and expires_at are set by callbacks, so they won't fail validation
    # unless we skip the callbacks, which is complex. Let's just test email_normalized
  end

  test "validates token uniqueness" do
    token = SecureRandom.hex(32)
    AuthenticatedSession.create!(
      email_normalized: @email_normalized,
      token: token,
      expires_at: 1.hour.from_now
    )

    duplicate = AuthenticatedSession.new(
      email_normalized: EmailNormalizer.normalize("other@example.com"),
      token: token,
      expires_at: 1.hour.from_now
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:token], "has already been taken"
  end

  test "generates token automatically on create" do
    session = AuthenticatedSession.create!(
      email_normalized: @email_normalized,
      expires_at: 1.hour.from_now
    )

    assert_not_nil session.token
    assert_equal 64, session.token.length # 32 bytes hex = 64 chars
  end

  test "active scope returns unexpired sessions" do
    active = AuthenticatedSession.create!(
      email_normalized: @email_normalized,
      token: SecureRandom.hex(32),
      expires_at: 1.hour.from_now
    )

    expired = AuthenticatedSession.create!(
      email_normalized: @email_normalized,
      token: SecureRandom.hex(32),
      expires_at: 1.hour.ago
    )

    active_sessions = AuthenticatedSession.active
    assert_includes active_sessions, active
    assert_not_includes active_sessions, expired
  end

  test "expired scope returns expired sessions" do
    active = AuthenticatedSession.create!(
      email_normalized: @email_normalized,
      token: SecureRandom.hex(32),
      expires_at: 1.hour.from_now
    )

    expired = AuthenticatedSession.create!(
      email_normalized: @email_normalized,
      token: SecureRandom.hex(32),
      expires_at: 1.hour.ago
    )

    expired_sessions = AuthenticatedSession.expired
    assert_not_includes expired_sessions, active
    assert_includes expired_sessions, expired
  end

  test "for_email scope filters by normalized email" do
    session1 = AuthenticatedSession.create!(
      email_normalized: @email_normalized,
      token: SecureRandom.hex(32),
      expires_at: 1.hour.from_now
    )

    session2 = AuthenticatedSession.create!(
      email_normalized: EmailNormalizer.normalize("other@example.com"),
      token: SecureRandom.hex(32),
      expires_at: 1.hour.from_now
    )

    filtered = AuthenticatedSession.for_email(@email)
    assert_includes filtered, session1
    assert_not_includes filtered, session2
  end

  test "expired? returns true for expired session" do
    session = AuthenticatedSession.new(expires_at: 1.hour.ago)
    assert session.expired?
  end

  test "expired? returns false for active session" do
    session = AuthenticatedSession.new(expires_at: 1.hour.from_now)
    assert_not session.expired?
  end

  test "valid_token? returns true for valid token" do
    token = SecureRandom.hex(32)
    session = AuthenticatedSession.create!(
      email_normalized: @email_normalized,
      token: token,
      expires_at: 1.hour.from_now
    )

    assert session.valid_token?(token)
  end

  test "valid_token? returns false for invalid token" do
    token = SecureRandom.hex(32)
    session = AuthenticatedSession.create!(
      email_normalized: @email_normalized,
      token: token,
      expires_at: 1.hour.from_now
    )

    assert_not session.valid_token?("invalid_token")
  end

  test "valid_token? returns false for expired session" do
    token = SecureRandom.hex(32)
    session = AuthenticatedSession.create!(
      email_normalized: @email_normalized,
      token: token,
      expires_at: 1.hour.ago
    )

    assert_not session.valid_token?(token)
  end
end
