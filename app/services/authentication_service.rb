require "digest"
require "securerandom"
require_relative "../lib/email_normalizer"

module AuthenticationService
  OTP_LENGTH = 4
  OTP_EXPIRY_MINUTES = 10
  SESSION_EXPIRY_HOURS = 1
  MAX_OTP_REQUESTS_PER_HOUR = 3
  MAX_OTP_ATTEMPTS = 5

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

      # Checking the code, counting the attempt and marking the OTP used happen
      # as one atomic step: the row is locked (SELECT ... FOR UPDATE) for the
      # whole check, so concurrent requests for the same OTP are serialized.
      # This keeps the attempt cap and single use intact under concurrency.
      #
      # The error is raised only after the transaction commits, so a counted
      # failed attempt is never rolled back by the exception.
      error = OtpVerification.transaction do
        check_and_consume_otp(email_normalized, code)
      end

      raise error if error

      true
    end

    # Runs inside a transaction. Locks the newest active OTP row for the email,
    # then checks it, counts the attempt or marks it used, all under that lock.
    # Returns nil on success, or the exception to raise after commit.
    def check_and_consume_otp(email_normalized, code)
      # FOR UPDATE: a concurrent request waits here until this transaction
      # commits, then Postgres re-checks the active scope on the updated row.
      otp_verification = OtpVerification.active
                                        .for_email(email_normalized)
                                        .order(created_at: :desc)
                                        .lock
                                        .first

      return InvalidOtp.new("Invalid or expired OTP") unless otp_verification

      # Check attempt lockout (MAX_OTP_ATTEMPTS)
      if otp_verification.attempts >= MAX_OTP_ATTEMPTS
        return InvalidOtp.new("Too many failed attempts. Please request a new OTP code.")
      end

      # Check if already verified
      if otp_verification.verified?
        return OtpAlreadyVerified.new("OTP has already been used")
      end

      # Check if expired
      if otp_verification.expired?
        otp_verification.increment_attempts!
        return OtpExpired.new("OTP has expired")
      end

      # Verify code using stored salt
      salt = otp_verification.salt
      stored_hash = otp_verification.code_hash
      provided_hash = Digest::SHA256.hexdigest("#{code}#{salt}")

      unless ActiveSupport::SecurityUtils.secure_compare(stored_hash, provided_hash)
        otp_verification.increment_attempts!
        return InvalidOtp.new("Invalid OTP code")
      end

      # Mark as verified (single use)
      otp_verification.mark_verified!

      nil
    end
    private :check_and_consume_otp

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
