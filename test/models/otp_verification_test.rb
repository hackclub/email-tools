require "test_helper"

class OtpVerificationTest < ActiveSupport::TestCase
  def setup
    @email = "test@example.com"
    @email_normalized = EmailNormalizer.normalize(@email)
  end

  test "validates required fields" do
    otp = OtpVerification.new
    assert_not otp.valid?
    assert_includes otp.errors[:email_normalized], "can't be blank"
    assert_includes otp.errors[:expires_at], "can't be blank"
    assert_includes otp.errors[:code_hash], "can't be blank"
    assert_includes otp.errors[:salt], "can't be blank"
  end

  test "active scope returns unexpired and unverified OTPs" do
    active = OtpVerification.create!(
      email_normalized: @email_normalized,
      code_hash: "hash1",
      salt: "salt1",
      expires_at: 10.minutes.from_now
    )

    expired = OtpVerification.create!(
      email_normalized: @email_normalized,
      code_hash: "hash2",
      salt: "salt2",
      expires_at: 1.minute.ago
    )

    verified = OtpVerification.create!(
      email_normalized: @email_normalized,
      code_hash: "hash3",
      salt: "salt3",
      expires_at: 10.minutes.from_now,
      verified_at: Time.current
    )

    active_otps = OtpVerification.active
    assert_includes active_otps, active
    assert_not_includes active_otps, expired
    assert_not_includes active_otps, verified
  end

  test "expired scope returns expired OTPs" do
    active = OtpVerification.create!(
      email_normalized: @email_normalized,
      code_hash: "hash1",
      salt: "salt1",
      expires_at: 10.minutes.from_now
    )

    expired = OtpVerification.create!(
      email_normalized: @email_normalized,
      code_hash: "hash2",
      salt: "salt2",
      expires_at: 1.minute.ago
    )

    expired_otps = OtpVerification.expired
    assert_not_includes expired_otps, active
    assert_includes expired_otps, expired
  end

  test "for_email scope filters by normalized email" do
    otp1 = OtpVerification.create!(
      email_normalized: @email_normalized,
      code_hash: "hash1",
      salt: "salt1",
      expires_at: 10.minutes.from_now
    )

    otp2 = OtpVerification.create!(
      email_normalized: EmailNormalizer.normalize("other@example.com"),
      code_hash: "hash2",
      salt: "salt2",
      expires_at: 10.minutes.from_now
    )

    filtered = OtpVerification.for_email(@email)
    assert_includes filtered, otp1
    assert_not_includes filtered, otp2
  end

  test "expired? returns true for expired OTP" do
    otp = OtpVerification.new(expires_at: 1.minute.ago)
    assert otp.expired?
  end

  test "expired? returns false for active OTP" do
    otp = OtpVerification.new(expires_at: 10.minutes.from_now)
    assert_not otp.expired?
  end

  test "verified? returns true when verified_at is set" do
    otp = OtpVerification.new(verified_at: Time.current)
    assert otp.verified?
  end

  test "verified? returns false when verified_at is nil" do
    otp = OtpVerification.new(verified_at: nil)
    assert_not otp.verified?
  end

  test "increment_attempts! increments attempts counter" do
    otp = OtpVerification.create!(
      email_normalized: @email_normalized,
      code_hash: "hash1",
      salt: "salt1",
      expires_at: 10.minutes.from_now,
      attempts: 0
    )

    otp.increment_attempts!
    assert_equal 1, otp.reload.attempts

    otp.increment_attempts!
    assert_equal 2, otp.reload.attempts
  end

  test "mark_verified! sets verified_at timestamp" do
    otp = OtpVerification.create!(
      email_normalized: @email_normalized,
      code_hash: "hash1",
      salt: "salt1",
      expires_at: 10.minutes.from_now
    )

    assert_nil otp.verified_at

    otp.mark_verified!
    assert_not_nil otp.reload.verified_at
  end
end
