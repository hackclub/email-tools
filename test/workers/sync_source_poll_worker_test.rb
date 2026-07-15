require "test_helper"
require "timeout"

class SyncSourcePollWorkerTest < ActiveSupport::TestCase
  # Disable parallelization for this test class since we're testing thread concurrency
  parallelize(workers: 1)

  # Disable transactional tests for this test class
  # Advisory locks are session-level, not transaction-level, so transactional
  # test fixtures can interfere with lock behavior
  self.use_transactional_tests = false

  def setup
    @sync_source = SyncSource.create!(
      source: "airtable",
      source_id: "app123",
      poll_interval_seconds: 30
    )
  end

  def teardown
    # Clean up any lingering advisory locks before cleanup
    cleanup_advisory_locks
    LoopsOutboxEnvelope.destroy_all  # Destroy envelopes before sync_sources
    SyncSource.destroy_all
    FieldValueBaseline.destroy_all
    # Final cleanup after data deletion
    cleanup_advisory_locks
  end

  test "prevents concurrent jobs from running simultaneously" do
    # Use Queue for proper thread synchronization
    # This ensures we can reliably coordinate between threads
    lock_acquired = Queue.new
    execution_count = { value: 0 }
    execution_mutex = Mutex.new

    # Create a mock poller that:
    # 1. Signals when it starts (lock is acquired and poller is executing)
    # 2. Blocks long enough for the second thread to attempt
    # 3. Tracks execution count
    mock_poller = Class.new do
      def initialize(lock_signal, counter, mutex)
        @lock_signal = lock_signal
        @counter = counter
        @mutex = mutex
      end

      def call(sync_source)
        # Signal that we've started executing (lock is held)
        @lock_signal.push(true) rescue nil

        # Increment execution counter
        @mutex.synchronize { @counter[:value] += 1 }

        # Block for enough time to ensure second thread attempts while we hold lock
        # This gives us confidence that the lock mechanism works
        sleep(0.5)
      end
    end.new(lock_acquired, execution_count, execution_mutex)

    # Stub Poller.for to return our mock
    original_for = Poller.method(:for)
    Poller.define_singleton_method(:for) { |_sync_source| mock_poller }

    begin
      # Clear any existing locks first
      cleanup_advisory_locks

      # Start first job in a thread - it will acquire lock
      # The worker already uses connection_pool.with_connection internally
      t1 = Thread.new do
        begin
          SyncSourcePollWorker.new.perform(@sync_source.id)
        rescue => e
          flunk("Thread 1 error: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
        end
      end

      # Wait for first thread to acquire lock and start executing poller
      # This ensures the lock is definitely held before second thread tries
      # The Queue.pop will block until the first thread signals it has the lock
      begin
        Timeout.timeout(3) do
          lock_acquired.pop
        end
      rescue Timeout::Error
        flunk("Timeout waiting for first thread to acquire lock - test setup issue")
      end

      # Small additional delay to ensure lock is fully established in the database
      sleep(0.1)

      # Now start second thread - should skip because lock is held
      # The worker will try to acquire the lock, fail, and return early
      t2 = Thread.new do
        begin
          SyncSourcePollWorker.new.perform(@sync_source.id)
        rescue => e
          flunk("Thread 2 error: #{e.class} - #{e.message}\n#{e.backtrace.join("\n")}")
        end
      end

      # Wait for both threads to complete
      unless t1.join(5)
        t1.kill
        flunk("Thread 1 did not complete within timeout")
      end
      unless t2.join(5)
        t2.kill
        flunk("Thread 2 did not complete within timeout")
      end

      # Verify only one execution occurred
      execution_mutex.synchronize do
        assert_equal 1, execution_count[:value],
          "Only one job should execute (got #{execution_count[:value]}). The lock should prevent concurrent execution."
      end
    ensure
      # Restore original method
      Poller.define_singleton_method(:for, original_for)
      # Clean up any remaining locks
      cleanup_advisory_locks
      # Ensure all threads are cleaned up
      [ t1, t2 ].each { |t| t.kill if t && t.alive? }
    end
  end

  test "allows second job after first completes" do
    execution_tracker = { count: 0, mutex: Mutex.new }

    # Create mock poller that tracks execution
    mock_poller = Class.new do
      def initialize(tracker)
        @tracker = tracker
      end

      def call(sync_source)
        @tracker[:mutex].synchronize { @tracker[:count] += 1 }
      end
    end.new(execution_tracker)

    original_for = Poller.method(:for)
    Poller.define_singleton_method(:for) { |_sync_source| mock_poller }

    begin
      # Run first job and wait for completion
      SyncSourcePollWorker.new.perform(@sync_source.id)

      # Small delay to ensure lock is released
      sleep(0.05)

      # Age the attempt past the backlog-duplicate guard so the second job
      # counts as due rather than as a queued duplicate
      @sync_source.update_columns(last_poll_attempted_at: 16.seconds.ago)

      # Run second job - should succeed now
      SyncSourcePollWorker.new.perform(@sync_source.id)
    ensure
      Poller.define_singleton_method(:for, original_for)
    end

    # Verify both executed
    assert_equal 2, execution_tracker[:count], "Both jobs should execute sequentially"
  end

  test "releases lock when job raises exception" do
    execution_tracker = { count: 0, mutex: Mutex.new, first_call: true }

    # Create mock poller - first call raises, second succeeds
    mock_poller = Class.new do
      def initialize(tracker)
        @tracker = tracker
      end

      def call(sync_source)
        @tracker[:mutex].synchronize do
          @tracker[:count] += 1
          if @tracker[:first_call]
            @tracker[:first_call] = false
            raise StandardError, "Test error"
          end
        end
      end
    end.new(execution_tracker)

    original_for = Poller.method(:for)
    Poller.define_singleton_method(:for) { |_sync_source| mock_poller }

    begin
      # Run first job - expect it to raise
      assert_raises(StandardError) do
        SyncSourcePollWorker.new.perform(@sync_source.id)
      end

      # Small delay to ensure lock is released
      sleep(0.05)

      # Age the attempt past the backlog-duplicate guard so the second job
      # counts as due rather than as a queued duplicate
      @sync_source.update_columns(last_poll_attempted_at: 16.seconds.ago)

      # Run second job - should succeed because lock was released
      SyncSourcePollWorker.new.perform(@sync_source.id)
    ensure
      Poller.define_singleton_method(:for, original_for)
    end

    # Verify both attempted (even though first failed)
    assert_equal 2, execution_tracker[:count], "Second job should run after first releases lock on error"
  end

  test "skips backlog duplicate when last attempt is fresher than half the poll interval" do
    @sync_source.update_columns(last_poll_attempted_at: 2.seconds.ago)
    previous_attempt = @sync_source.reload.last_poll_attempted_at

    call_tracker = { count: 0 }
    mock_poller = Class.new do
      def initialize(call_counter)
        @call_counter = call_counter
      end

      def call(sync_source)
        @call_counter[:count] += 1
      end
    end.new(call_tracker)

    original_for = Poller.method(:for)
    Poller.define_singleton_method(:for) { |_sync_source| mock_poller }

    begin
      SyncSourcePollWorker.new.perform(@sync_source.id)
    ensure
      Poller.define_singleton_method(:for, original_for)
    end

    assert_equal 0, call_tracker[:count], "Poller should not run for a backlog duplicate"
    assert_equal previous_attempt, @sync_source.reload.last_poll_attempted_at,
      "Skipped duplicate should not mark a new attempt"
  end

  test "polls when last attempt is older than half the poll interval" do
    @sync_source.update_columns(last_poll_attempted_at: 16.seconds.ago)

    call_tracker = { count: 0 }
    mock_poller = Class.new do
      def initialize(call_counter)
        @call_counter = call_counter
      end

      def call(sync_source)
        @call_counter[:count] += 1
      end
    end.new(call_tracker)

    original_for = Poller.method(:for)
    Poller.define_singleton_method(:for) { |_sync_source| mock_poller }

    begin
      SyncSourcePollWorker.new.perform(@sync_source.id)
    ensure
      Poller.define_singleton_method(:for, original_for)
    end

    assert_equal 1, call_tracker[:count], "Poller should run when the source is due"
  end

  test "different sync_source IDs do not interfere" do
    sync_source2 = SyncSource.create!(
      source: "airtable",
      source_id: "app456",
      poll_interval_seconds: 30
    )

    execution_tracker = { count: 0, mutex: Mutex.new }

    # Create mock poller that tracks execution
    mock_poller = Class.new do
      def initialize(tracker)
        @tracker = tracker
      end

      def call(sync_source)
        @tracker[:mutex].synchronize { @tracker[:count] += 1 }
      end
    end.new(execution_tracker)

    original_for = Poller.method(:for)
    Poller.define_singleton_method(:for) { |_sync_source| mock_poller }

    begin
      threads = []

      # Start both jobs concurrently with different IDs
      threads << Thread.new do
        SyncSourcePollWorker.new.perform(@sync_source.id)
      end

      threads << Thread.new do
        SyncSourcePollWorker.new.perform(sync_source2.id)
      end

      threads.each(&:join)
    ensure
      Poller.define_singleton_method(:for, original_for)
    end

    # Both should execute since they use different lock keys
    assert_equal 2, execution_tracker[:count], "Jobs for different sync_sources should not interfere"
  end

  test "works normally when no concurrent job exists" do
    execution_tracker = { count: 0, mutex: Mutex.new }

    mock_poller = Class.new do
      def initialize(tracker, expected_sync_source)
        @tracker = tracker
        @expected_sync_source = expected_sync_source
      end

      def call(sync_source)
        @tracker[:mutex].synchronize do
          @tracker[:count] += 1
          # Don't assert here - it would raise and be caught by worker's rescue
          # Just verify the sync_source is correct in the test itself
        end
        # Verify outside the mutex to avoid raising in the worker
        raise "Wrong sync_source" unless @expected_sync_source.id == sync_source.id
      end
    end.new(execution_tracker, @sync_source)

    original_for = Poller.method(:for)
    Poller.define_singleton_method(:for) { |_sync_source| mock_poller }

    begin
      SyncSourcePollWorker.new.perform(@sync_source.id)
    ensure
      Poller.define_singleton_method(:for, original_for)
    end

    assert_equal 1, execution_tracker[:count], "Job should execute normally"
    @sync_source.reload
    assert_not_nil @sync_source.last_poll_attempted_at, "Should mark attempt"
  end

  test "skips when sync_source does not exist" do
    non_existent_id = 99999

    # Create a poller that should not be called
    # Use a hash so we can track calls by reference
    call_tracker = { count: 0 }
    mock_poller = Class.new do
      def initialize(call_counter)
        @call_counter = call_counter
      end

      def call(sync_source)
        @call_counter[:count] += 1
      end
    end.new(call_tracker)

    original_for = Poller.method(:for)
    Poller.define_singleton_method(:for) { |_sync_source| mock_poller }

    begin
      # Should not raise, just return early
      assert_nothing_raised do
        SyncSourcePollWorker.new.perform(non_existent_id)
      end
    ensure
      Poller.define_singleton_method(:for, original_for)
    end

    # Mock should not be called - check the hash that was actually modified
    assert_equal 0, call_tracker[:count], "Poller should not be called when sync_source doesn't exist"
  end

  private

  def cleanup_advisory_locks
    # Clean up any advisory locks that might be left over from tests
    # This uses the same connection pool to ensure cleanup
    connection = ApplicationRecord.connection
    # Release all advisory locks held by this session
    connection.execute("SELECT pg_advisory_unlock_all()")
  rescue => e
    # Ignore errors during cleanup
    Rails.logger.debug("Advisory lock cleanup: #{e.message}") if defined?(Rails)
  end
end
