require "test_helper"

class AuthenticationServiceTest < ActiveSupport::TestCase
  def setup
    skip "Redis not available" unless REDIS_FOR_RATE_LIMITING.ping

    @email = "test@example.com"
    @email_normalized = EmailNormalizer.normalize(@email)

    # Clear rate limits
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{@email_normalized}")

    # Clean up any existing OTPs and sessions
    OtpVerification.where(email_normalized: @email_normalized).delete_all
    AuthenticatedSession.where(email_normalized: @email_normalized).delete_all
  end

  def teardown
    # Clean up
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{@email_normalized}")
    OtpVerification.where(email_normalized: @email_normalized).delete_all
    AuthenticatedSession.where(email_normalized: @email_normalized).delete_all
  end

  test "generate_otp creates 4-digit code" do
    code = AuthenticationService.generate_otp(@email)

    assert_match(/\A\d{4}\z/, code)
    assert_equal 4, code.length

    otp = OtpVerification.last
    assert_equal @email_normalized, otp.email_normalized
    assert_not_nil otp.code_hash
    assert_not_nil otp.salt
    assert otp.expires_at > Time.current
    assert_nil otp.verified_at
  end

  test "generate_otp raises error for blank email" do
    assert_raises(ArgumentError) do
      AuthenticationService.generate_otp("")
    end

    assert_raises(ArgumentError) do
      AuthenticationService.generate_otp(nil)
    end
  end

  test "generate_otp respects rate limit" do
    # Generate 3 OTPs (the limit)
    3.times do
      AuthenticationService.generate_otp(@email)
    end

    # 4th should fail
    assert_raises(AuthenticationService::RateLimitExceeded) do
      AuthenticationService.generate_otp(@email)
    end
  end

  test "verify_otp succeeds with correct code" do
    code = AuthenticationService.generate_otp(@email)
    result = AuthenticationService.verify_otp(@email, code)

    assert_equal true, result

    otp = OtpVerification.last
    assert_not_nil otp.verified_at
  end

  test "verify_otp fails with incorrect code" do
    code = AuthenticationService.generate_otp(@email)

    assert_raises(AuthenticationService::InvalidOtp) do
      AuthenticationService.verify_otp(@email, "0000")
    end

    otp = OtpVerification.last
    assert_nil otp.verified_at
    assert otp.attempts > 0
  end

  test "verify_otp fails with expired code" do
    code = AuthenticationService.generate_otp(@email)
    otp = OtpVerification.last
    # Expire it - it won't be in active scope anymore
    otp.update!(expires_at: 1.minute.ago)

    # Since expired OTPs aren't in active scope, it raises InvalidOtp
    assert_raises(AuthenticationService::InvalidOtp) do
      AuthenticationService.verify_otp(@email, code)
    end
  end

  test "verify_otp fails if already verified" do
    code = AuthenticationService.generate_otp(@email)
    AuthenticationService.verify_otp(@email, code)

    # After verification, the OTP won't be in active scope, so it raises InvalidOtp
    assert_raises(AuthenticationService::InvalidOtp) do
      AuthenticationService.verify_otp(@email, code)
    end
  end

  test "create_session generates valid session token" do
    token = AuthenticationService.create_session(@email)

    assert_not_nil token
    assert_equal 64, token.length # 32 bytes hex = 64 chars

    session = AuthenticatedSession.last
    assert_equal @email_normalized, session.email_normalized
    assert_equal token, session.token
    assert session.expires_at > Time.current
  end

  test "validate_session returns email for valid token" do
    token = AuthenticationService.create_session(@email)
    email = AuthenticationService.validate_session(token)

    assert_equal @email_normalized, email
  end

  test "validate_session returns nil for invalid token" do
    result = AuthenticationService.validate_session("invalid_token")
    assert_nil result
  end

  test "validate_session returns nil for expired session" do
    token = AuthenticationService.create_session(@email)
    session = AuthenticatedSession.last
    session.update!(expires_at: 1.hour.ago)

    result = AuthenticationService.validate_session(token)
    assert_nil result
  end

  test "verify_otp locks out after 5 failed attempts" do
    code = AuthenticationService.generate_otp(@email)
    otp = OtpVerification.last

    # Make 5 failed attempts
    5.times do
      assert_raises(AuthenticationService::InvalidOtp) do
        AuthenticationService.verify_otp(@email, "0000")
      end
      otp.reload
    end

    # Should have 5 attempts
    assert_equal 5, otp.attempts

    # 6th attempt should be locked out
    assert_raises(AuthenticationService::InvalidOtp) do
      AuthenticationService.verify_otp(@email, "0000")
    end

    # Even correct code should fail after lockout
    assert_raises(AuthenticationService::InvalidOtp) do
      AuthenticationService.verify_otp(@email, code)
    end

    # Error message should mention lockout
    begin
      AuthenticationService.verify_otp(@email, code)
    rescue AuthenticationService::InvalidOtp => e
      assert_match(/Too many failed attempts/i, e.message)
    end
  end

  test "verify_otp resets attempts when new OTP is generated" do
    # Generate first OTP and make some failed attempts
    code1 = AuthenticationService.generate_otp(@email)
    otp1 = OtpVerification.last

    3.times do
      assert_raises(AuthenticationService::InvalidOtp) do
        AuthenticationService.verify_otp(@email, "0000")
      end
      otp1.reload
    end

    assert_equal 3, otp1.attempts

    # Generate new OTP - should reset attempt counter
    code2 = AuthenticationService.generate_otp(@email)
    otp2 = OtpVerification.last

    # New OTP should have 0 attempts
    assert_equal 0, otp2.attempts

    # Should be able to verify new OTP
    result = AuthenticationService.verify_otp(@email, code2)
    assert_equal true, result
  end

  test "destroy_session expires session" do
    token = AuthenticationService.create_session(@email)
    session = AuthenticatedSession.find_by(token: token)

    assert session.expires_at > Time.current
    assert_not session.expired?

    # Destroy session
    AuthenticationService.destroy_session(token)

    session.reload
    assert session.expires_at <= Time.current
    assert session.expired?

    # Session should no longer be valid
    result = AuthenticationService.validate_session(token)
    assert_nil result
  end

  test "destroy_session handles invalid token gracefully" do
    # Should not raise error for invalid token
    assert_nothing_raised do
      AuthenticationService.destroy_session("invalid_token")
    end
  end

  test "destroy_session handles nil token gracefully" do
    assert_nothing_raised do
      AuthenticationService.destroy_session(nil)
    end
  end
end
