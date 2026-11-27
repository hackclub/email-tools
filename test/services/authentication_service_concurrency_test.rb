require "test_helper"
require "minitest/mock"
require "timeout"

# Service-level concurrency tests for AuthenticationService.verify_otp, which
# both sign-in and email change use. Each thread checks out its own Postgres
# connection, so transactional tests are off for this class.
class AuthenticationServiceConcurrencyTest < ActiveSupport::TestCase
  parallelize(workers: 1)
  self.use_transactional_tests = false

  THREADS = 4
  SLOW_COMPARE_SECONDS = 0.2

  def setup
    skip "Redis not available" unless REDIS_FOR_RATE_LIMITING.ping

    @email = "otp-service-race@example.com"
    @email_normalized = EmailNormalizer.normalize(@email)
    cleanup
  end

  def teardown
    cleanup
  end

  test "concurrent wrong guesses cannot exceed the attempt limit" do
    code = AuthenticationService.generate_otp(@email)
    otp = OtpVerification.for_email(@email).last
    otp.update_columns(attempts: AuthenticationService::MAX_OTP_ATTEMPTS - 2)

    outcomes = race(THREADS) { AuthenticationService.verify_otp(@email, wrong_code(code)) }

    assert outcomes.all? { |o| o == AuthenticationService::InvalidOtp }, outcomes.inspect
    assert_equal AuthenticationService::MAX_OTP_ATTEMPTS, otp.reload.attempts

    error = assert_raises(AuthenticationService::InvalidOtp) do
      AuthenticationService.verify_otp(@email, code)
    end
    assert_match(/Too many failed attempts/i, error.message)
    assert_nil otp.reload.verified_at
  end

  test "a correct code is consumed exactly once under concurrent requests" do
    code = AuthenticationService.generate_otp(@email)

    outcomes = race(THREADS) { AuthenticationService.verify_otp(@email, code) }

    assert_equal 1, outcomes.count(:ok), outcomes.inspect
    assert_equal THREADS - 1, outcomes.count(AuthenticationService::InvalidOtp), outcomes.inspect
    assert_not_nil OtpVerification.for_email(@email).last.verified_at
  end

  # With two active OTPs for one email, a request that waits on the newest
  # row's lock can fall through to the older active row (Postgres re-checks
  # the locked row, then LIMIT 1 takes the next one). The cap and single use
  # must still hold per row.
  test "with two active OTPs the cap and single use hold per row under concurrency" do
    older_code, older = create_otp(created_at: 1.minute.ago, code: "1111")
    newer_code, newer = create_otp(created_at: Time.current, code: "2222")
    cap = AuthenticationService::MAX_OTP_ATTEMPTS
    older.update_columns(attempts: cap - 1)
    newer.update_columns(attempts: cap - 2)

    wrong = "3333"
    assert_not_includes [ older_code, newer_code ], wrong
    outcomes = race(THREADS) { AuthenticationService.verify_otp(@email, wrong) }
    assert_equal 0, outcomes.count(:ok), outcomes.inspect
    assert_operator older.reload.attempts, :<=, cap
    assert_operator newer.reload.attempts, :<=, cap

    # Fresh rows for the single-use check.
    OtpVerification.where(email_normalized: @email_normalized).delete_all
    _older_code, older = create_otp(created_at: 1.minute.ago, code: "1111")
    newer_code, newer = create_otp(created_at: Time.current, code: "2222")

    outcomes = race(THREADS) { AuthenticationService.verify_otp(@email, newer_code) }
    assert_equal 1, outcomes.count(:ok), outcomes.inspect
    assert_not_nil newer.reload.verified_at
    # Waiters that fell through to the older row were checked against the
    # older code, so it was not consumed.
    assert_nil older.reload.verified_at
    assert_operator older.attempts, :<=, cap
    # Documents the fall-through: every waiter was counted on the older row.
    assert_equal THREADS - 1, older.attempts
  end

  test "a failed attempt is still counted when verify_otp raises" do
    code = AuthenticationService.generate_otp(@email)

    assert_raises(AuthenticationService::InvalidOtp) do
      AuthenticationService.verify_otp(@email, wrong_code(code))
    end

    assert_equal 1, OtpVerification.for_email(@email).last.attempts
  end

  private

  def cleanup
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{@email_normalized}")
    OtpVerification.where(email_normalized: @email_normalized).delete_all
  end

  # Creates an OTP row directly (bypasses the Redis rate limiter, whose keys
  # other parallel test workers share). Returns [code, record].
  def create_otp(created_at:, code: format("%04d", SecureRandom.random_number(10_000)))
    salt = SecureRandom.hex(16)
    otp = OtpVerification.create!(
      email_normalized: @email_normalized,
      code_hash: Digest::SHA256.hexdigest("#{code}#{salt}"),
      salt: salt,
      expires_at: AuthenticationService::OTP_EXPIRY_MINUTES.minutes.from_now,
      created_at: created_at
    )
    [ code, otp ]
  end

  def wrong_code(code)
    format("%04d", (code.to_i + 1) % 10_000)
  end

  # Returns :ok or the exception class for each concurrent call.
  def race(count)
    ready = Queue.new
    go = Queue.new
    results = Queue.new

    original_compare = ActiveSupport::SecurityUtils.method(:secure_compare)
    slow_compare = lambda do |a, b|
      sleep SLOW_COMPARE_SECONDS
      original_compare.call(a, b)
    end

    ActiveSupport::SecurityUtils.stub(:secure_compare, slow_compare) do
      threads = Array.new(count) do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            go.pop
            yield
            results << :ok
          rescue AuthenticationService::InvalidOtp, AuthenticationService::OtpAlreadyVerified => e
            results << e.class
          rescue => e
            results << "#{e.class}: #{e.message}"
          end
        end
      end

      Timeout.timeout(5) { count.times { ready.pop } }
      count.times { go << true }
      threads.each do |t|
        next if t.join(30)

        t.kill
        flunk("Concurrent verify did not finish in time")
      end
    end

    Array.new(count) { results.pop }
  end
end
