require "test_helper"
require "minitest/mock"

class ProfileUpdateControllerTest < ActionDispatch::IntegrationTest
  def setup
    skip "Redis not available" unless REDIS_FOR_RATE_LIMITING.ping
    
    @email = "test@example.com"
    @email_normalized = EmailNormalizer.normalize(@email)
    
    # Clear rate limits before each test
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{@email_normalized}")
    
    # Clean up any existing data
    OtpVerification.where(email_normalized: @email_normalized).delete_all
    AuthenticatedSession.where(email_normalized: @email_normalized).delete_all
    LoopsContactChangeAudit.where(email_normalized: @email_normalized).delete_all
    
    # Mock LoopsService responses
    @mock_contact = {
      "firstName" => "John",
      "lastName" => "Doe",
      "genderSelfReported" => "male",
      "birthday" => "1990-01-15T00:00:00.000Z",
      "addressLine1" => "123 Main St",
      "addressLine2" => nil,
      "addressCity" => "Springfield",
      "addressState" => "IL",
      "addressZipCode" => "62701",
      "addressCountry" => "USA"
    }
    
    @mock_update_response = { "success" => true, "id" => "test_id_123" }
    
    # Set test transactional ID
    @original_transactional_id = ENV["LOOPS_OTP_TRANSACTIONAL_ID"]
    ENV["LOOPS_OTP_TRANSACTIONAL_ID"] = "test_transactional_id"
  end

  # HTTP client stub that mimics LoopsService HTTPX client
  class SimpleHttpResponse
    def initialize(status:, body:)
      @status = status
      @body = body
    end
    def error
      nil
    end
    def status
      @status
    end
    def body
      @body
    end
    def headers
      {}
    end
    def json
      JSON.parse(@body)
    end
  end

  def with_loops_http_stub
    contact_body = JSON.generate([@mock_contact])
    update_body = JSON.generate(@mock_update_response)

    http_client = Object.new
    http_client.define_singleton_method(:get) do |url|
      SimpleHttpResponse.new(status: 200, body: contact_body)
    end
    http_client.define_singleton_method(:put) do |url, json:|
      SimpleHttpResponse.new(status: 200, body: update_body)
    end

    LoopsService.stub(:http_client, http_client) do
      yield
    end
  end

  # Capture payload sent to LoopsService.update_contact
  def with_capture_update
    original = LoopsService.method(:update_contact)
    captured = []
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      captured << { email: email, payload: kwargs }
      { "success" => true, "id" => "test_id_123" }
    end
    begin
      yield captured
    ensure
      LoopsService.define_singleton_method(:update_contact, original)
    end
  end

  # Stub out baseline/audit side effects to avoid exceptions in integration tests
  def silence_audit_side_effects
    original_baseline = LoopsFieldBaseline.method(:find_or_create_baseline)
    original_audit_create = LoopsContactChangeAudit.method(:create!)

    LoopsFieldBaseline.define_singleton_method(:find_or_create_baseline) do |email_normalized:, field_name:|
      obj = Object.new
      obj.define_singleton_method(:last_sent_value) { nil }
      obj.define_singleton_method(:update_sent_value) { |value:, expires_in_days:| true }
      obj
    end

    LoopsContactChangeAudit.define_singleton_method(:create!) do |**kwargs|
      true
    end

    begin
      yield
    ensure
      LoopsFieldBaseline.define_singleton_method(:find_or_create_baseline, original_baseline)
      LoopsContactChangeAudit.define_singleton_method(:create!, original_audit_create)
    end
  end

  def teardown
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{@email_normalized}")
    OtpVerification.where(email_normalized: @email_normalized).delete_all
    AuthenticatedSession.where(email_normalized: @email_normalized).delete_all
    LoopsContactChangeAudit.where(email_normalized: @email_normalized).delete_all
    
    ENV["LOOPS_OTP_TRANSACTIONAL_ID"] = @original_transactional_id if @original_transactional_id
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

  # Helper to set up LoopsService stubs for update tests
  def with_loops_service_stubs
    mock_response = @mock_update_response.dup
    mock_contact_array = [@mock_contact]
    original_update_contact = LoopsService.method(:update_contact)
    original_find_contact = LoopsService.method(:find_contact)
    
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      mock_response
    end
    
    LoopsService.define_singleton_method(:find_contact) do |**args|
      mock_contact_array
    end
    
    begin
      yield
    ensure
      LoopsService.define_singleton_method(:update_contact, original_update_contact)
      LoopsService.define_singleton_method(:find_contact, original_find_contact)
    end
  end

  test "edit requires authentication" do
    get profile_edit_path
    assert_redirected_to auth_otp_request_path
  end

  test "update requires authentication" do
    patch profile_path, params: { firstName: "Jane" }
    assert_redirected_to auth_otp_request_path
  end

  # Test the full flow end-to-end instead of stubbing
  test "full flow: request OTP, verify, edit profile, update profile" do
    # Step 1: Request OTP
    code = AuthenticationService.generate_otp(@email)
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      AuthenticationService.stub(:generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
        assert_redirected_to auth_otp_verify_path
      end
    end
    
    # Step 2: Verify OTP
    post auth_otp_verify_path, params: { code: code }
    assert_redirected_to profile_edit_path
    follow_redirect! # Clear flash
    
    with_loops_http_stub do
      # Step 3: Edit profile (should load data)
      get profile_edit_path
      assert_response :success
      assert_match(/John/, response.body)

      # Step 4: Update profile (assert payload sent)
      with_capture_update do |captured|
        silence_audit_side_effects do
          patch profile_path, params: { firstName: "Jane" }
          assert_redirected_to profile_edit_path
          assert_equal 1, captured.size
          assert_equal "test@example.com", captured.first[:email]
          assert_equal "Jane", captured.first[:payload]["firstName"]
        end
      end
    end
  end

  test "update allows editing one address field when others already stored" do
    authenticate_user

    with_loops_http_stub do
      with_capture_update do |captured|
        silence_audit_side_effects do
          patch profile_path, params: {
            addressLine1: "456 New St"
          }

          assert_redirected_to profile_edit_path
          follow_redirect! if response.redirect?
          assert_nil flash[:error]
          assert_equal 1, captured.size
          assert_equal "456 New St", captured.first[:payload]["addressLine1"]
        end
      end
    end
  end

  test "update validates address fields when no address previously stored" do
    authenticate_user

    no_address_contact = @mock_contact.merge(
      "addressLine1" => nil,
      "addressCity" => nil,
      "addressState" => nil,
      "addressZipCode" => nil,
      "addressCountry" => nil
    )

    LoopsService.stub(:find_contact, ->(**args) { [no_address_contact] }) do
      patch profile_path, params: {
        addressLine1: "456 New St"
      }

      assert_redirected_to profile_edit_path
      assert_match(/required/i, flash[:error])
    end
  end

  test "update allows editing addressLine2 independently" do
    # Authenticate first
    authenticate_user
    
    with_loops_http_stub do
      with_capture_update do |captured|
        silence_audit_side_effects do
          # Update only addressLine2 - don't include birthday fields
          patch profile_path, params: {
            addressLine2: "Apt 5",
            birthdayYear: "",
            birthdayMonth: "",
            birthdayDay: ""
          }
          
          assert_redirected_to profile_edit_path
          follow_redirect! if response.redirect?
          assert_nil flash[:error]
          assert_equal 1, captured.size
          assert_equal "test@example.com", captured.first[:email]
          assert_equal "Apt 5", captured.first[:payload]["addressLine2"]
          assert_nil captured.first[:payload]["addressLine1"]
        end
      end
    end
  end

  test "update validates birthday fields" do
    # Authenticate first
    authenticate_user
    
    LoopsService.stub(:find_contact, ->(**args) { [@mock_contact] }) do
      # Try to update only year
      patch profile_path, params: {
        birthdayYear: "1991",
        birthdayMonth: "",
        birthdayDay: ""
      }
      
      assert_redirected_to profile_edit_path
      assert_match(/all fields.*required/i, flash[:error])
    end
  end

  test "update validates birthday date" do
    # Authenticate first
    authenticate_user
    
    LoopsService.stub(:find_contact, ->(**args) { [@mock_contact] }) do
      # Invalid date
      patch profile_path, params: {
        birthdayYear: "1990",
        birthdayMonth: "13", # Invalid month
        birthdayDay: "32" # Invalid day
      }
      
      assert_redirected_to profile_edit_path
      assert_match(/Invalid date/i, flash[:error])
    end
  end

  test "update shows no changes message when nothing changed" do
    # Authenticate first
    authenticate_user
    
    LoopsService.stub(:find_contact, ->(**args) { [@mock_contact] }) do
      # Submit form with all same values
      patch profile_path, params: {
        firstName: "John",
        lastName: "Doe",
        genderSelfReported: "male",
        birthdayYear: "1990",
        birthdayMonth: "1",
        birthdayDay: "15"
      }
      
      assert_redirected_to profile_edit_path
      assert_equal "No changes detected", flash[:notice]
    end
  end

  test "update creates audit log with is_self_service flag" do
    # Authenticate first
    authenticate_user
    
    with_loops_http_stub do
      patch profile_path, params: { firstName: "Jane" }
      
      # Verify the response was successful
      assert_redirected_to profile_edit_path
      follow_redirect! if response.redirect?
      assert_nil flash[:error], "Update should succeed, but got error: #{flash[:error]}"
      
      # Wait a moment for async operations if any
      sleep 0.1
      
      audit = LoopsContactChangeAudit.where(email_normalized: @email_normalized).last
      assert_not_nil audit, "Audit log should be created"
      assert_equal "firstName", audit.field_name
      assert_equal true, audit.is_self_service
      assert_nil audit.sync_source_id
      assert_equal "profile_update", audit.provenance["purpose"]
    end
  end

  test "update preserves nonstandard gender value when form submits empty" do
    # Authenticate first
    authenticate_user
    
    # Set up a contact with a nonstandard gender value
    nonstandard_contact = @mock_contact.dup
    nonstandard_contact["genderSelfReported"] = "she/her"
    
    LoopsService.stub(:find_contact, ->(**args) { [nonstandard_contact] }) do
      with_capture_update do |captured|
        silence_audit_side_effects do
          # Submit form with empty genderSelfReported (form can't match nonstandard value)
          # and update firstName to ensure we're actually making a change
          patch profile_path, params: {
            firstName: "Jane",
            genderSelfReported: "" # Empty because form can't match "she/her"
          }
          
          assert_redirected_to profile_edit_path
          follow_redirect! if response.redirect?
          assert_nil flash[:error]
          
          # Verify that genderSelfReported was NOT included in the update payload
          assert_equal 1, captured.size
          assert_equal "test@example.com", captured.first[:email]
          assert_equal "Jane", captured.first[:payload]["firstName"]
          assert_nil captured.first[:payload]["genderSelfReported"], 
            "genderSelfReported should not be included in update when form submits empty for nonstandard value"
        end
      end
    end
  end

  test "update includes standard gender value when changed" do
    # Authenticate first
    authenticate_user
    
    # Set up a contact with a standard gender value
    contact_with_male = @mock_contact.dup
    contact_with_male["genderSelfReported"] = "male"
    
    LoopsService.stub(:find_contact, ->(**args) { [contact_with_male] }) do
      with_capture_update do |captured|
        silence_audit_side_effects do
          # Change gender from male to female
          patch profile_path, params: {
            genderSelfReported: "female"
          }
          
          assert_redirected_to profile_edit_path
          follow_redirect! if response.redirect?
          assert_nil flash[:error]
          
          # Verify that genderSelfReported WAS included in the update payload
          assert_equal 1, captured.size
          assert_equal "female", captured.first[:payload]["genderSelfReported"]
        end
      end
    end
  end

  test "update does not include blank fields in payload" do
    # Authenticate first
    authenticate_user
    
    with_capture_update do |captured|
      silence_audit_side_effects do
        # Submit form with only firstName set, others blank
        patch profile_path, params: {
          firstName: "Jane",
          lastName: "",
          genderSelfReported: "",
          addressLine1: "",
          addressCity: "",
          addressState: "",
          addressZipCode: "",
          addressCountry: ""
        }
        
        assert_redirected_to profile_edit_path
        follow_redirect! if response.redirect?
        assert_nil flash[:error]
        
        # Verify only firstName is in the payload (non-blank values only)
        assert_equal 1, captured.size
        payload = captured.first[:payload]
        assert_equal "Jane", payload["firstName"]
        assert_nil payload["lastName"], "Blank lastName should not be included"
        assert_nil payload["genderSelfReported"], "Blank genderSelfReported should not be included"
        assert_nil payload["addressLine1"], "Blank addressLine1 should not be included"
      end
    end
  end
end
