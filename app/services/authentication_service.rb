require "digest"
require "securerandom"
require_relative "../lib/email_normalizer"

module AuthenticationService
  OTP_LENGTH = 4
  OTP_EXPIRY_MINUTES = 10
  SESSION_EXPIRY_HOURS = 1
  MAX_OTP_REQUESTS_PER_HOUR = 3

  class RateLimitExceeded < StandardError; end
  class InvalidOtp < StandardError; end
  class OtpExpired < StandardError; end
  class OtpAlreadyVerified < StandardError; end

  class << self
    def generate_otp(email)
      email_normalized = EmailNormalizer.normalize(email)
      raise ArgumentError, "Email is required" if email_normalized.blank?

      # Check rate limit
      rate_limit_check(email_normalized)

      # Generate 4-digit OTP
      code = format("%0#{OTP_LENGTH}d", SecureRandom.random_number(10**OTP_LENGTH))

      # Generate salt and hash the code
      salt = SecureRandom.hex(16)
      code_hash = Digest::SHA256.hexdigest("#{code}#{salt}")

      # Store in database
      OtpVerification.create!(
        email_normalized: email_normalized,
        code_hash: code_hash,
        salt: salt,
        expires_at: OTP_EXPIRY_MINUTES.minutes.from_now
      )

      code
    end

    def verify_otp(email, code)
      email_normalized = EmailNormalizer.normalize(email)
      raise ArgumentError, "Email is required" if email_normalized.blank?
      raise ArgumentError, "Code is required" if code.blank?

      # Find active, unverified OTP for this email
      otp_verification = OtpVerification.active
                                        .for_email(email_normalized)
                                        .order(created_at: :desc)
                                        .first

      unless otp_verification
        otp_verification&.increment_attempts!
        raise InvalidOtp, "Invalid or expired OTP"
      end

      # Check attempt lockout (max 5 attempts)
      if otp_verification.attempts >= 5
        raise InvalidOtp, "Too many failed attempts. Please request a new OTP code."
      end

      # Check if already verified
      if otp_verification.verified?
        raise OtpAlreadyVerified, "OTP has already been used"
      end

      # Check if expired
      if otp_verification.expired?
        otp_verification.increment_attempts!
        raise OtpExpired, "OTP has expired"
      end

      # Verify code using stored salt
      salt = otp_verification.salt
      stored_hash = otp_verification.code_hash
      provided_hash = Digest::SHA256.hexdigest("#{code}#{salt}")

      unless ActiveSupport::SecurityUtils.secure_compare(stored_hash, provided_hash)
        otp_verification.increment_attempts!
        raise InvalidOtp, "Invalid OTP code"
      end

      # Mark as verified
      otp_verification.mark_verified!

      true
    end

    def create_session(email)
      email_normalized = EmailNormalizer.normalize(email)
      raise ArgumentError, "Email is required" if email_normalized.blank?

      # Create new session
      session = AuthenticatedSession.create!(
        email_normalized: email_normalized,
        expires_at: SESSION_EXPIRY_HOURS.hours.from_now
      )

      session.token
    end

    def validate_session(token)
      return nil if token.blank?

      session = AuthenticatedSession.active.find_by(token: token)
      return nil unless session
      return nil if session.expired?

      session.email_normalized
    end

    def destroy_session(token)
      return if token.blank?

      session = AuthenticatedSession.find_by(token: token)
      return unless session

      # Expire the session by setting expires_at to current time
      session.update!(expires_at: Time.current)
    end

    def rate_limit_check(email_normalized)
      rate_limiter = RateLimiter.new(
        redis: REDIS_FOR_RATE_LIMITING,
        key: "rate:otp:#{email_normalized}",
        limit: MAX_OTP_REQUESTS_PER_HOUR,
        period: 3600.0 # 1 hour in seconds
      )

      # Try to acquire - this will block if at limit, but we want to fail fast
      # For web requests, we want non-blocking behavior
      # Let's check if we can acquire without blocking by checking the count first
      redis_key = "rate:otp:#{email_normalized}"
      count = REDIS_FOR_RATE_LIMITING.zcard(redis_key).to_i

      if count >= MAX_OTP_REQUESTS_PER_HOUR
        raise RateLimitExceeded, "Too many OTP requests. Please try again later."
      end

      # Acquire the slot (this will add to the count)
      rate_limiter.acquire!
    end
  end
end
