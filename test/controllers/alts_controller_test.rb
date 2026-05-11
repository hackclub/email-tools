require "test_helper"
require "minitest/mock"

class AltsControllerTest < ActionDispatch::IntegrationTest
  def setup
    skip "Redis not available" unless REDIS_FOR_RATE_LIMITING.ping

    @email = "zach@hackclub.com"
    @email_normalized = EmailNormalizer.normalize(@email)

    # Clear rate limits before each test
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{@email_normalized}")

    # Clean up any existing data
    OtpVerification.where(email_normalized: @email_normalized).delete_all
    AuthenticatedSession.where(email_normalized: @email_normalized).delete_all
  end

  def teardown
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{@email_normalized}")
    OtpVerification.where(email_normalized: @email_normalized).delete_all
    AuthenticatedSession.where(email_normalized: @email_normalized).delete_all
  end

  # Helper to authenticate and set up session
  def authenticate_user
    # Generate OTP code first
    code = AuthenticationService.generate_otp(@email)

    # Request OTP (sets session[:otp_email])
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
    end

    # Verify OTP (sets session[:auth_token])
    post auth_otp_verify_path, params: { code: code }
    # Clear flash after authentication by following redirect
    follow_redirect! if response.redirect?
  end

  test "index requires authentication" do
    get alts_path
    assert_redirected_to auth_otp_request_path
  end

  test "index shows found subscribed alt emails" do
    authenticate_user

    mock_alts = {
      subscribed: [ "zach+test@hackclub.com", "zach+test2@hackclub.com" ],
      unsubscribed: []
    }
    AltFinderService.stub(:call, mock_alts) do
      get alts_path
      assert_response :success
      assert_match(/zach\+test@hackclub\.com/, response.body)
      assert_match(/zach\+test2@hackclub\.com/, response.body)
    end
  end

  test "index shows unsubscribed alt emails" do
    authenticate_user

    mock_alts = {
      subscribed: [],
      unsubscribed: [ "zach+old@hackclub.com", "zach+unsubscribed@hackclub.com" ]
    }
    AltFinderService.stub(:call, mock_alts) do
      get alts_path
      assert_response :success
      assert_match(/zach\+old@hackclub\.com/, response.body)
      assert_match(/zach\+unsubscribed@hackclub\.com/, response.body)
      assert_match(/already.*unsubscribed/i, response.body)
    end
  end

  test "index shows both subscribed and unsubscribed alt emails" do
    authenticate_user

    mock_alts = {
      subscribed: [ "zach+test@hackclub.com" ],
      unsubscribed: [ "zach+old@hackclub.com" ]
    }
    AltFinderService.stub(:call, mock_alts) do
      get alts_path
      assert_response :success
      assert_match(/zach\+test@hackclub\.com/, response.body)
      assert_match(/zach\+old@hackclub\.com/, response.body)
    end
  end

  test "index shows message when no alts found" do
    authenticate_user

    AltFinderService.stub(:call, { subscribed: [], unsubscribed: [] }) do
      get alts_path
      assert_response :success
      assert_match(/did not find any subscribed \+alt emails/, response.body)
    end
  end

  test "index handles AltFinderService errors gracefully" do
    authenticate_user

    AltFinderService.stub(:call, ->(main_email:) { raise "Database error" }) do
      get alts_path
      assert_response :success
      assert_match(/Could not retrieve \+alt emails/, response.body)
      # Should show message when no subscribed alts found
      assert_match(/did not find any subscribed \+alt emails/, response.body)
    end
  end

  test "unsubscribe requires authentication" do
    post alts_unsubscribe_path, params: { alts: [ "zach+test@hackclub.com" ] }
    assert_redirected_to auth_otp_request_path
  end

  test "unsubscribe enqueues job with valid alts" do
    authenticate_user

    verified_alts = [ "zach+test@hackclub.com", "zach+test2@hackclub.com" ]

    MassUnsubscribeJob.stub(:perform_async, ->(main_email, alts) {
      assert_equal @email, main_email
      assert_equal verified_alts, alts
      "job_id_123"
    }) do
      post alts_unsubscribe_path, params: { alts: verified_alts }
      assert_redirected_to alts_path
      assert_match(/Unsubscription process started/, flash[:notice])
    end
  end

  test "unsubscribe filters out invalid alt emails" do
    authenticate_user

    valid_alts = [ "zach+test@hackclub.com" ]
    invalid_alts = [ "other@example.com", "notanalt@hackclub.com" ]

    MassUnsubscribeJob.stub(:perform_async, ->(main_email, alts) {
      assert_equal @email, main_email
      assert_equal valid_alts, alts
      "job_id_123"
    }) do
      post alts_unsubscribe_path, params: { alts: valid_alts + invalid_alts }
      assert_redirected_to alts_path
    end
  end

  test "unsubscribe rejects non-plus-alias emails" do
    authenticate_user

    invalid_alts = [ "other@example.com" ]

    post alts_unsubscribe_path, params: { alts: invalid_alts }
    assert_redirected_to alts_path
    assert_match(/No valid \+alt emails/, flash[:error])
  end

  test "unsubscribe rejects alts from different domain" do
    authenticate_user

    invalid_alts = [ "zach+test@example.com" ] # Different domain

    post alts_unsubscribe_path, params: { alts: invalid_alts }
    assert_redirected_to alts_path
    assert_match(/No valid \+alt emails/, flash[:error])
  end

  test "unsubscribe rejects alts from different user" do
    authenticate_user

    invalid_alts = [ "other+test@hackclub.com" ] # Different user part

    post alts_unsubscribe_path, params: { alts: invalid_alts }
    assert_redirected_to alts_path
    assert_match(/No valid \+alt emails/, flash[:error])
  end

  test "unsubscribe handles empty alts array" do
    authenticate_user

    post alts_unsubscribe_path, params: { alts: [] }
    assert_redirected_to alts_path
    assert_match(/No valid \+alt emails/, flash[:error])
  end

  test "unsubscribe validates plus-alias pattern strictly" do
    authenticate_user

    # These should all be rejected
    invalid_cases = [
      "zach@hackclub.com", # No plus
      "zach+@hackclub.com", # Plus but no alias part
      "zach+test" # No domain
    ]

    invalid_cases.each do |invalid_alt|
      post alts_unsubscribe_path, params: { alts: [ invalid_alt ] }
      assert_redirected_to alts_path
      assert_match(/No valid \+alt emails/, flash[:error])
    end
  end
end
