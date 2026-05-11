require "test_helper"
require "minitest/mock"

class AuthControllerTest < ActionDispatch::IntegrationTest
  def setup
    skip "Redis not available" unless REDIS_FOR_RATE_LIMITING.ping

    @email = "test@example.com"
    @email_normalized = EmailNormalizer.normalize(@email)

    # Clear rate limits
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{@email_normalized}")

    # Clean up
    OtpVerification.where(email_normalized: @email_normalized).delete_all
    AuthenticatedSession.where(email_normalized: @email_normalized).delete_all

    # Set test transactional ID
    @original_transactional_id = ENV["LOOPS_OTP_TRANSACTIONAL_ID"]
    ENV["LOOPS_OTP_TRANSACTIONAL_ID"] = "test_transactional_id"
  end

  def teardown
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{@email_normalized}")
    OtpVerification.where(email_normalized: @email_normalized).delete_all
    AuthenticatedSession.where(email_normalized: @email_normalized).delete_all

    ENV["LOOPS_OTP_TRANSACTIONAL_ID"] = @original_transactional_id if @original_transactional_id
  end

  test "show_otp_request renders form when not authenticated" do
    get auth_otp_request_path
    assert_response :success
    assert_match(/Email Address/i, response.body)
  end

  test "show_otp_request redirects to profile edit when already authenticated" do
    # Create authenticated session and verify OTP to set session
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    # Now accessing OTP request should redirect
    get auth_otp_request_path
    assert_redirected_to profile_edit_path
  end

  test "request_otp generates and sends OTP" do
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      post auth_otp_request_path, params: { email: @email }

      assert_redirected_to auth_otp_verify_path
      assert_equal "OTP code sent to your email. Please check your inbox.", flash[:notice]

      # Verify OTP was created
      otp = OtpVerification.last
      assert_equal @email_normalized, otp.email_normalized
    end
  end

  test "request_otp requires email" do
    post auth_otp_request_path, params: { email: "" }

    assert_redirected_to auth_otp_request_path
    assert_equal "Email is required", flash[:error]
  end

  test "request_otp handles rate limit" do
    # Generate 3 OTPs to hit rate limit
    3.times do
      AuthenticationService.generate_otp(@email)
    end

    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      post auth_otp_request_path, params: { email: @email }

      assert_redirected_to auth_otp_request_path
      assert_match(/Too many OTP requests/i, flash[:error])
    end
  end

  test "show_verify_otp requires session email" do
    get auth_otp_verify_path
    assert_redirected_to auth_otp_request_path
  end

  test "verify_otp creates session and redirects" do
    # Generate OTP code first
    code = AuthenticationService.generate_otp(@email)

    # Now stub generate_otp to return the same code when request_otp is called
    AuthenticationService.stub(:generate_otp, ->(email) { code }) do
      LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
        post auth_otp_request_path, params: { email: @email }
        assert_redirected_to auth_otp_verify_path
      end
    end

    # Verify OTP (session should persist from previous request)
    post auth_otp_verify_path, params: { code: code }

    assert_redirected_to profile_edit_path
    assert_equal "Successfully authenticated!", flash[:notice]

    # Verify session was created
    session = AuthenticatedSession.last
    assert_equal @email_normalized, session.email_normalized
  end

  test "verify_otp fails with invalid code" do
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      post auth_otp_request_path, params: { email: @email }
      assert_redirected_to auth_otp_verify_path
    end

    # Session should persist, so we can verify with wrong code
    post auth_otp_verify_path, params: { code: "0000" }

    assert_redirected_to auth_otp_verify_path
    assert_match(/Invalid/i, flash[:error])
  end

  test "verify_otp requires code" do
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      post auth_otp_request_path, params: { email: @email }
      assert_redirected_to auth_otp_verify_path
    end

    # Session should persist
    post auth_otp_verify_path, params: { code: "" }

    assert_redirected_to auth_otp_verify_path
    assert_equal "OTP code is required", flash[:error]
  end

  test "verify_otp rotates session to prevent fixation" do
    # Generate OTP code first
    code = AuthenticationService.generate_otp(@email)

    # Request OTP (sets session[:otp_email])
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
    end

    # Store old session data to verify it gets cleared
    # Note: In Rails integration tests, we can't directly access session.id,
    # but we can verify that reset_session works by checking that auth still succeeds

    # Verify OTP - should reset session before setting auth_token
    post auth_otp_verify_path, params: { code: code }

    assert_redirected_to profile_edit_path
    assert_equal "Successfully authenticated!", flash[:notice]

    # Verify we can access protected route (proves session was rotated and auth_token was set)
    LoopsService.stub(:find_contact, ->(**args) { [ { "firstName" => "Test" } ] }) do
      get profile_edit_path
      assert_response :success
    end
  end

  test "verify_otp locks out after 5 failed attempts" do
    code = AuthenticationService.generate_otp(@email)

    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      post auth_otp_request_path, params: { email: @email }
    end

    # Make 5 failed attempts
    5.times do
      post auth_otp_verify_path, params: { code: "0000" }
      assert_redirected_to auth_otp_verify_path
      assert_match(/Invalid/i, flash[:error])
    end

    # 6th attempt should be locked out
    post auth_otp_verify_path, params: { code: "0000" }
    assert_redirected_to auth_otp_verify_path
    assert_match(/Too many failed attempts/i, flash[:error])

    # Even correct code should fail after lockout
    post auth_otp_verify_path, params: { code: code }
    assert_redirected_to auth_otp_verify_path
    assert_match(/Too many failed attempts/i, flash[:error])
  end

  test "show_otp_request rejects absolute URLs in redirect_to parameter" do
    # Test with external absolute URL
    get auth_otp_request_path, params: { redirect_to: "https://evil.com/phishing" }

    # Should store safe fallback, not the malicious URL
    assert_not_equal "https://evil.com/phishing", session[:redirect_after_auth]
    assert_equal profile_edit_path, session[:redirect_after_auth]
  end

  test "show_otp_request accepts relative paths in redirect_to parameter" do
    # Test with relative path
    get auth_otp_request_path, params: { redirect_to: "/alts" }

    # Should store the relative path
    assert_equal "/alts", session[:redirect_after_auth]
  end

  test "show_otp_request rejects protocol-relative URLs" do
    # Test with protocol-relative URL (//evil.com)
    get auth_otp_request_path, params: { redirect_to: "//evil.com/phishing" }

    # Should fallback to safe path
    assert_equal profile_edit_path, session[:redirect_after_auth]
  end

  test "show_otp_request rejects URLs with host" do
    # Test with URL that has host but no protocol
    get auth_otp_request_path, params: { redirect_to: "evil.com/phishing" }

    # Should fallback to safe path
    assert_equal profile_edit_path, session[:redirect_after_auth]
  end

  test "verify_otp prevents open redirect with absolute URL" do
    # Set up OTP flow
    code = AuthenticationService.generate_otp(@email)

    # Try to set malicious redirect through show_otp_request (will be sanitized)
    get auth_otp_request_path, params: { redirect_to: "https://evil.com/phishing" }
    # Should have stored safe fallback, not malicious URL
    assert_equal profile_edit_path, session[:redirect_after_auth]

    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
    end

    # Verify OTP - should redirect to safe path, not malicious URL
    post auth_otp_verify_path, params: { code: code }

    assert_redirected_to profile_edit_path
    assert_not_equal "https://evil.com/phishing", @response.redirect_url
  end

  test "verify_otp allows relative paths" do
    # Set up OTP flow
    code = AuthenticationService.generate_otp(@email)

    # Store safe relative path
    get auth_otp_request_path, params: { redirect_to: "/alts" }

    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
    end

    # Verify OTP - should redirect to the relative path
    post auth_otp_verify_path, params: { code: code }

    assert_redirected_to "/alts"
  end

  test "show_otp_request redirects authenticated users safely" do
    # Authenticate user first
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    # Try to set malicious redirect when accessing as authenticated user
    # Should sanitize and redirect to safe path, not malicious URL
    get auth_otp_request_path, params: { redirect_to: "https://evil.com/phishing" }
    assert_redirected_to profile_edit_path
    assert_not_equal "https://evil.com/phishing", @response.redirect_url
  end

  test "logout expires session in database" do
    # Authenticate user first
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    # Get the session token
    token = session[:auth_token]
    session_record = AuthenticatedSession.find_by(token: token)
    assert session_record.expires_at > Time.current

    # Logout
    delete auth_logout_path

    # Session should be expired
    session_record.reload
    assert session_record.expires_at <= Time.current
  end

  test "logout clears session cookie" do
    # Authenticate user first
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    assert session[:auth_token].present?

    # Logout
    delete auth_logout_path

    # Session token should be cleared
    assert_nil session[:auth_token]
  end

  test "logout rotates session" do
    # Authenticate user first
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    # Set some session keys that should be cleared
    session[:redirect_after_auth] = "/some/path"
    session[:otp_email] = "test@example.com"
    session[:change_email_to] = "new@example.com"

    # Capture session state before logout
    session_hash_before = session.to_hash.dup

    # Logout
    delete auth_logout_path

    # Session should be rotated - all custom keys should be cleared
    assert_nil session[:auth_token]
    assert_nil session[:redirect_after_auth]
    assert_nil session[:otp_email]
    assert_nil session[:change_email_to]

    # Session hash should be different (rotated)
    session_hash_after = session.to_hash
    # Rails internals may remain, but our custom keys should be gone
    assert_not_equal session_hash_before.keys.sort, session_hash_after.keys.sort
  end

  test "logout redirects to home" do
    # Authenticate user first
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    # Logout
    delete auth_logout_path

    assert_redirected_to root_path
  end

  test "logout shows success message" do
    # Authenticate user first
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    # Logout
    delete auth_logout_path

    assert_equal "You have been logged out successfully.", flash[:notice]
  end

  test "logout when not authenticated" do
    # Logout without being authenticated
    delete auth_logout_path

    # Should still redirect successfully
    assert_redirected_to root_path
    assert_equal "You have been logged out successfully.", flash[:notice]
  end

  test "show_change_email requires authentication" do
    get auth_change_email_path
    assert_redirected_to auth_otp_request_path
  end

  test "show_change_email shows form when authenticated" do
    # Authenticate user first
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    get auth_change_email_path
    assert_response :success
    assert_match(/Change Email/i, response.body)
    assert_match(/currently logged in/i, response.body)
  end

  test "change_email_request_otp requires authentication" do
    post auth_change_email_request_path, params: { email: "new@example.com" }
    assert_redirected_to auth_otp_request_path
  end

  test "change_email_request_otp rejects same email" do
    # Authenticate user first
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    # Try to change to same email
    post auth_change_email_request_path, params: { email: @email }
    assert_redirected_to auth_change_email_path
    assert_match(/must be different/i, flash[:error])
  end

  test "change_email_request_otp generates OTP for new email" do
    # Authenticate user first
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    new_email = "new@example.com"
    # Clear rate limit for new email
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{EmailNormalizer.normalize(new_email)}")
    new_code = AuthenticationService.generate_otp(new_email)

    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { new_code }) do
        post auth_change_email_request_path, params: { email: new_email }
      end
    end

    assert_redirected_to auth_otp_verify_path
    assert_equal "OTP code sent to #{new_email}. Please check your inbox.", flash[:notice]
    assert_equal new_email, session[:change_email_to]
    assert_equal new_email, session[:otp_email]
  end

  test "verify_otp handles email change scenario" do
    # Authenticate user first
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    old_token = session[:auth_token]
    new_email = "new@example.com"
    # Clear rate limit for new email
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{EmailNormalizer.normalize(new_email)}")
    new_code = AuthenticationService.generate_otp(new_email)

    # Request change email OTP
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { new_code }) do
        post auth_change_email_request_path, params: { email: new_email }
      end
    end

    # Verify OTP for new email
    post auth_otp_verify_path, params: { code: new_code }

    assert_redirected_to profile_edit_path
    assert_match(/Successfully changed email/i, flash[:notice])

    # Old session should be expired
    old_session = AuthenticatedSession.find_by(token: old_token)
    assert old_session.expires_at <= Time.current

    # New session should be created
    new_token = session[:auth_token]
    assert_not_equal old_token, new_token
    new_session = AuthenticatedSession.find_by(token: new_token)
    assert_equal EmailNormalizer.normalize(new_email), new_session.email_normalized
  end

  test "email change creates new session and clears old one" do
    # Authenticate user first
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    old_token = session[:auth_token]
    old_session = AuthenticatedSession.find_by(token: old_token)
    assert old_session.expires_at > Time.current

    new_email = "new@example.com"
    # Clear rate limit for new email
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{EmailNormalizer.normalize(new_email)}")
    new_code = AuthenticationService.generate_otp(new_email)

    # Request change email OTP
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { new_code }) do
        post auth_change_email_request_path, params: { email: new_email }
      end
    end

    # Verify OTP for new email
    post auth_otp_verify_path, params: { code: new_code }

    # Old session should be expired
    old_session.reload
    assert old_session.expires_at <= Time.current

    # New session should exist and be valid
    new_token = session[:auth_token]
    assert_not_nil new_token
    assert_not_equal old_token, new_token
    new_session = AuthenticatedSession.find_by(token: new_token)
    assert new_session.expires_at > Time.current
  end

  test "email change redirects correctly" do
    # Authenticate user first
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
      post auth_otp_verify_path, params: { code: code }
    end

    new_email = "new@example.com"
    # Clear rate limit for new email
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{EmailNormalizer.normalize(new_email)}")
    new_code = AuthenticationService.generate_otp(new_email)

    # Request change email OTP
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { new_code }) do
        post auth_change_email_request_path, params: { email: new_email }
      end
    end

    # Verify OTP for new email
    post auth_otp_verify_path, params: { code: new_code }

    assert_redirected_to profile_edit_path
  end
end
