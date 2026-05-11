class AuthController < ApplicationController
  skip_before_action :authenticate_admin
  before_action :require_authenticated_session, only: [ :show_change_email, :change_email_request_otp ]

  def show_otp_request
    # Check if user is already authenticated
    token = session[:auth_token]
    email = AuthenticationService.validate_session(token)

    if email
      # Already authenticated, redirect to intended destination or profile edit
      destination = safe_path(session[:redirect_after_auth] || profile_edit_path)
      session.delete(:redirect_after_auth)
      session.delete(:auth_purpose)
      redirect_to destination
      return
    end

    # Store redirect destination if provided
    if params[:redirect_to].present?
      session[:redirect_after_auth] = safe_path(params[:redirect_to])
    end

    # Store auth purpose based on redirect destination for context-aware UI
    # Only set if not already set (e.g., from require_authenticated_session)
    unless session[:auth_purpose].present?
      redirect_path = session[:redirect_after_auth]
      set_auth_purpose_from_path(redirect_path)
      # Default to profile_update if no redirect path and no redirect_to param
      if session[:auth_purpose].blank? && params[:redirect_to].blank?
        session[:auth_purpose] = "profile_update"
      end
    end

    # Not authenticated, show OTP request form
  end

  def request_otp
    email = params[:email]&.strip

    if email.blank?
      flash[:error] = "Email is required"
      redirect_to auth_otp_request_path
      return
    end

    begin
      code = AuthenticationService.generate_otp(email)

      # Send OTP via Loops transactional email
      transactional_id = ENV.fetch("LOOPS_OTP_TRANSACTIONAL_ID")
      LoopsService.send_transactional_email(
        email: email,
        transactional_id: transactional_id,
        data_variables: { otp_code: code }
      )

      # Store email in session for verification step
      session[:otp_email] = email

      flash[:notice] = "OTP code sent to your email. Please check your inbox."
      redirect_to auth_otp_verify_path
    rescue AuthenticationService::RateLimitExceeded => e
      flash[:error] = e.message
      redirect_to auth_otp_request_path
    rescue => e
      Rails.logger.error("AuthController#request_otp error: #{e.class} - #{e.message}")
      flash[:error] = "Failed to send OTP. Please try again."
      redirect_to auth_otp_request_path
    end
  end

  def show_verify_otp
    # Show OTP verification form
    @email = session[:otp_email]
    redirect_to auth_otp_request_path if @email.blank?
  end

  def verify_otp
    # Check if this is an email change scenario
    if session[:change_email_to].present?
      new_email = session[:change_email_to]
      code = params[:code]&.strip

      if code.blank?
        flash[:error] = "OTP code is required"
        redirect_to auth_otp_verify_path
        return
      end

      begin
        AuthenticationService.verify_otp(new_email, code)

        # Get old token before clearing session
        old_token = session[:auth_token]

        # Store redirect destination before reset_session clears it
        destination = safe_path(profile_edit_path)

        # Rotate session to prevent fixation attacks
        reset_session

        # Expire old session
        AuthenticationService.destroy_session(old_token) if old_token.present?

        # Create new authenticated session for new email
        token = AuthenticationService.create_session(new_email)

        # Store token in session cookie (after reset_session)
        session[:auth_token] = token

        flash[:notice] = "Successfully changed email to #{new_email}!"
        redirect_to destination
      rescue AuthenticationService::InvalidOtp, AuthenticationService::OtpExpired, AuthenticationService::OtpAlreadyVerified => e
        flash[:error] = e.message
        redirect_to auth_otp_verify_path
      rescue => e
        Rails.logger.error("AuthController#verify_otp (change email) error: #{e.class} - #{e.message}")
        flash[:error] = "Failed to verify OTP. Please try again."
        redirect_to auth_otp_verify_path
      end
      return
    end

    # Normal OTP verification flow
    email = session[:otp_email]
    code = params[:code]&.strip

    if email.blank?
      flash[:error] = "Session expired. Please request a new OTP."
      redirect_to auth_otp_request_path
      return
    end

    if code.blank?
      flash[:error] = "OTP code is required"
      redirect_to auth_otp_verify_path
      return
    end

    begin
      AuthenticationService.verify_otp(email, code)

      # Store redirect destination before reset_session clears it
      destination = safe_path(session[:redirect_after_auth] || profile_edit_path)

      # Rotate session to prevent fixation attacks
      reset_session

      # Create authenticated session
      token = AuthenticationService.create_session(email)

      # Store token in session cookie (after reset_session)
      session[:auth_token] = token

      flash[:notice] = "Successfully authenticated!"
      redirect_to destination
    rescue AuthenticationService::InvalidOtp, AuthenticationService::OtpExpired, AuthenticationService::OtpAlreadyVerified => e
      flash[:error] = e.message
      redirect_to auth_otp_verify_path
    rescue => e
      Rails.logger.error("AuthController#verify_otp error: #{e.class} - #{e.message}")
      flash[:error] = "Failed to verify OTP. Please try again."
      redirect_to auth_otp_verify_path
    end
  end

  def logout
    old_token = session[:auth_token]
    AuthenticationService.destroy_session(old_token) if old_token.present?
    reset_session
    flash[:notice] = "You have been logged out successfully."
    redirect_to root_path
  end

  def show_change_email
    @current_email = current_authenticated_email
  end

  def change_email_request_otp
    current_email = current_authenticated_email
    new_email = params[:email]&.strip

    if new_email.blank?
      flash[:error] = "Email is required"
      redirect_to auth_change_email_path
      return
    end

    new_email_normalized = EmailNormalizer.normalize(new_email)
    current_email_normalized = EmailNormalizer.normalize(current_email)

    if new_email_normalized == current_email_normalized
      flash[:error] = "New email must be different from your current email."
      redirect_to auth_change_email_path
      return
    end

    begin
      code = AuthenticationService.generate_otp(new_email)

      # Send OTP via Loops transactional email
      transactional_id = ENV.fetch("LOOPS_OTP_TRANSACTIONAL_ID")
      LoopsService.send_transactional_email(
        email: new_email,
        transactional_id: transactional_id,
        data_variables: { otp_code: code }
      )

      # Store new email in session for verification step
      session[:change_email_to] = new_email
      session[:otp_email] = new_email  # Also set for the verify page to show email

      flash[:notice] = "OTP code sent to #{new_email}. Please check your inbox."
      redirect_to auth_otp_verify_path
    rescue AuthenticationService::RateLimitExceeded => e
      flash[:error] = e.message
      redirect_to auth_change_email_path
    rescue => e
      Rails.logger.error("AuthController#change_email_request_otp error: #{e.class} - #{e.message}")
      flash[:error] = "Failed to send OTP. Please try again."
      redirect_to auth_change_email_path
    end
  end

  private

  def safe_path(path)
    return profile_edit_path if path.blank?

    path_str = path.to_s.strip

    # Reject protocol-relative URLs (//evil.com)
    return profile_edit_path if path_str.start_with?("//")

    # Reject absolute URLs with protocol (https://, http://, etc.)
    return profile_edit_path if path_str.match?(/\A[a-z][a-z0-9+.-]*:/i)

    # Parse as URI to check for host component
    uri = URI.parse(path_str) rescue nil

    # Reject if URI parsing failed
    return profile_edit_path unless uri

    # Reject if URI has a host (absolute URL)
    return profile_edit_path if uri.host.present?

    # Reject if path doesn't start with "/" (relative paths must start with /)
    return profile_edit_path unless uri.path&.start_with?("/")

    # Accept relative paths that start with "/"
    uri.to_s
  end
end
