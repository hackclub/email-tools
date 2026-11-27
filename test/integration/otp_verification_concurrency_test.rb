require "test_helper"
require "minitest/mock"
require "timeout"

# Concurrency tests for OTP verification through the real controller paths
# (sign-in and email change).
#
# Each thread drives its own integration session that carries the same Rails
# session cookie, so the requests look like one browser racing itself. The
# requests hit Postgres on separate connections, so transactional tests are
# off for this class.
#
# The Loops transport is stubbed: no network call is made and no email is sent.
# The stub records the OTP code the controller would have emailed.
class OtpVerificationConcurrencyTest < ActionDispatch::IntegrationTest
  parallelize(workers: 1)
  self.use_transactional_tests = false

  # Main thread holds one connection; the default pool is 5.
  THREADS = 4

  # Widens the window between reading the OTP row and writing to it. Without
  # an atomic check-count-consume step, concurrent requests all read the same
  # row state inside this window.
  SLOW_COMPARE_SECONDS = 0.2

  def setup
    skip "Redis not available" unless REDIS_FOR_RATE_LIMITING.ping

    @email = "otp-race@example.com"
    @new_email = "otp-race-new@example.com"
    @emails = [ @email, @new_email ].map { |e| EmailNormalizer.normalize(e) }
    cleanup

    @original_transactional_id = ENV["LOOPS_OTP_TRANSACTIONAL_ID"]
    ENV["LOOPS_OTP_TRANSACTIONAL_ID"] = "test_transactional_id"

    @sent_emails = Queue.new
  end

  def teardown
    cleanup
    ENV["LOOPS_OTP_TRANSACTIONAL_ID"] = @original_transactional_id
  end

  test "sign-in: concurrent wrong guesses cannot exceed the attempt limit" do
    with_stubbed_loops { post auth_otp_request_path, params: { email: @email } }
    code = sent_code_for(@email)
    otp = latest_otp(@email)
    otp.update_columns(attempts: AuthenticationService::MAX_OTP_ATTEMPTS - 2)

    responses = race(THREADS) { |s| s.post auth_otp_verify_path, params: { code: wrong_code(code) } }

    assert responses.all? { |r| r[:location].end_with?(auth_otp_verify_path) }
    assert_equal AuthenticationService::MAX_OTP_ATTEMPTS, otp.reload.attempts,
      "Attempts must stop at the cap under concurrent wrong guesses"
    assert_nil otp.verified_at

    # The correct code is rejected once the cap is reached.
    post auth_otp_verify_path, params: { code: code }
    assert_redirected_to auth_otp_verify_path
    assert_match(/Too many failed attempts/i, flash[:error])
    assert_nil otp.reload.verified_at
    assert_equal 0, AuthenticatedSession.where(email_normalized: @emails.first).count
  end

  test "sign-in: a correct code is consumed exactly once under concurrent requests" do
    with_stubbed_loops { post auth_otp_request_path, params: { email: @email } }
    code = sent_code_for(@email)

    responses = race(THREADS) { |s| s.post auth_otp_verify_path, params: { code: code } }

    successes = responses.count { |r| r[:location].end_with?(profile_edit_path) }
    assert_equal 1, successes, "Exactly one request may sign in with a single-use code (responses: #{responses.inspect})"
    assert_equal 1, AuthenticatedSession.where(email_normalized: @emails.first).count
    assert_not_nil latest_otp(@email).verified_at
  end

  test "email change: concurrent wrong guesses cannot exceed the attempt limit" do
    sign_in_and_request_email_change
    code = sent_code_for(@new_email)
    otp = latest_otp(@new_email)
    otp.update_columns(attempts: AuthenticationService::MAX_OTP_ATTEMPTS - 2)

    responses = race(THREADS) { |s| s.post auth_otp_verify_path, params: { code: wrong_code(code) } }

    assert responses.all? { |r| r[:location].end_with?(auth_otp_verify_path) }
    assert_equal AuthenticationService::MAX_OTP_ATTEMPTS, otp.reload.attempts,
      "Attempts must stop at the cap under concurrent wrong guesses"
    assert_nil otp.verified_at

    post auth_otp_verify_path, params: { code: code }
    assert_redirected_to auth_otp_verify_path
    assert_match(/Too many failed attempts/i, flash[:error])
    assert_equal 0, AuthenticatedSession.where(email_normalized: @emails.last).count
  end

  test "email change: a correct code is consumed exactly once under concurrent requests" do
    sign_in_and_request_email_change
    code = sent_code_for(@new_email)

    responses = race(THREADS) { |s| s.post auth_otp_verify_path, params: { code: code } }

    successes = responses.count { |r| r[:location].end_with?(profile_edit_path) }
    assert_equal 1, successes, "Exactly one request may change the email with a single-use code (responses: #{responses.inspect})"
    assert_equal 1, AuthenticatedSession.where(email_normalized: @emails.last).count
    assert_not_nil latest_otp(@new_email).verified_at
  end

  private

  def cleanup
    @emails.each do |email|
      REDIS_FOR_RATE_LIMITING.del("rate:otp:#{email}")
      OtpVerification.where(email_normalized: email).delete_all
      AuthenticatedSession.where(email_normalized: email).delete_all
    end
  end

  # Stub the Loops transport. Records the OTP code instead of sending email.
  def with_stubbed_loops(&block)
    recorder = lambda do |email:, data_variables: {}, **_rest|
      @sent_emails << [ EmailNormalizer.normalize(email), data_variables[:otp_code] ]
      { "success" => true, "test_stub" => true }
    end
    LoopsService.stub(:send_transactional_email, recorder, &block)
  end

  def sent_code_for(email)
    normalized = EmailNormalizer.normalize(email)
    sent = []
    sent << @sent_emails.pop until @sent_emails.empty?
    code = sent.reverse.find { |to, _| to == normalized }&.last
    assert_match(/\A\d{4}\z/, code, "Stubbed Loops transport should have recorded a 4-digit code for #{email}")
    code
  end

  def sign_in_and_request_email_change
    with_stubbed_loops { post auth_otp_request_path, params: { email: @email } }
    post auth_otp_verify_path, params: { code: sent_code_for(@email) }
    assert_redirected_to profile_edit_path

    with_stubbed_loops { post auth_change_email_request_path, params: { email: @new_email } }
    assert_redirected_to auth_otp_verify_path
  end

  def latest_otp(email)
    OtpVerification.for_email(email).order(created_at: :desc).first
  end

  def wrong_code(code)
    format("%04d", (code.to_i + 1) % 10_000)
  end

  # Runs the block concurrently in `count` integration sessions that share
  # this test's session cookie. Returns one { status:, location: } per thread.
  def race(count)
    cookie_jar = cookies.to_hash
    sessions = Array.new(count) do
      open_session.tap { |s| cookie_jar.each { |name, value| s.cookies[name] = value } }
    end

    ready = Queue.new
    go = Queue.new
    results = Queue.new

    original_compare = ActiveSupport::SecurityUtils.method(:secure_compare)
    slow_compare = lambda do |a, b|
      sleep SLOW_COMPARE_SECONDS
      original_compare.call(a, b)
    end

    ActiveSupport::SecurityUtils.stub(:secure_compare, slow_compare) do
      threads = sessions.map do |s|
        Thread.new do
          ready << true
          go.pop
          yield s
          results << { status: s.response.status, location: s.response.location.to_s }
        rescue => e
          results << { error: "#{e.class}: #{e.message}", location: "" }
        end
      end

      Timeout.timeout(5) { count.times { ready.pop } }
      count.times { go << true }
      threads.each do |t|
        next if t.join(30)

        t.kill
        flunk("Concurrent request did not finish in time")
      end
    end

    Array.new(count) { results.pop }.tap do |all|
      errors = all.select { |r| r[:error] }
      assert_empty errors, "Concurrent requests raised: #{errors.inspect}"
    end
  end
end
