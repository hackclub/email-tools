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
