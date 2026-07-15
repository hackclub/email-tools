class SyncSourcePollWorker
  include Sidekiq::Worker

  sidekiq_options queue: :polling

  # Advisory lock namespace for preventing concurrent execution
  # This namespace isolates our locks from other advisory locks in the system
  # The value is arbitrary but documented here for clarity
  ADVISORY_LOCK_NAMESPACE = 0x53535057  # ASCII: "SSPW" (SyncSourcePollWorker)

  # The enqueuer reserves next_poll_at forward when it enqueues, so it emits
  # exactly one job per source per poll interval. When the polling queue runs
  # behind, several of those jobs for the same source sit in the queue at
  # once; the advisory lock serializes them but each would still run a full
  # poll back-to-back. A job that arrives sooner than this fraction of the
  # poll interval after the previous attempt is such a backlog duplicate and
  # is skipped. Jitter is at most ±10%, so on-schedule jobs always clear it.
  DUPLICATE_SKIP_FRACTION = 0.5

  def perform(id)
    # Use PostgreSQL advisory lock to prevent concurrent execution
    # Advisory locks are per-connection, so we use with_connection to ensure
    # the connection is bound to this thread for all ActiveRecord operations
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      # Try to acquire lock (non-blocking)
      # Namespace separates our locks from other advisory locks in the system
      result = connection.execute(
        "SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_NAMESPACE}, #{connection.quote(id)})"
      )

      # Check if lock was acquired (result is a boolean)
      lock_acquired = result.first["pg_try_advisory_lock"]

      # If we couldn't acquire the lock, another job is already running
      unless lock_acquired
        Rails.logger.info("SyncSourcePollWorker: Skipping #{id} - already running")
        return
      end

      begin
        s = SyncSource.find_by(id: id)
        return unless s

        min_gap_seconds = s.poll_interval_seconds * DUPLICATE_SKIP_FRACTION
        if s.last_poll_attempted_at && s.last_poll_attempted_at > min_gap_seconds.seconds.ago
          Rails.logger.info("SyncSourcePollWorker: Skipping #{id} - last attempt #{(Time.current - s.last_poll_attempted_at).round(1)}s ago, backlog duplicate")
          return
        end

        s.mark_attempt!

        begin
          Poller.for(s).call(s)   # <-- this invokes your per-source logic
          s.mark_success!
        rescue => e
          s.mark_failure!(message: e.message, klass: e.class.name, at: Time.current)
          raise
        end
      ensure
        # Always release the lock, even if there's an error
        # Must use the same connection that acquired the lock
        connection.execute(
          "SELECT pg_advisory_unlock(#{ADVISORY_LOCK_NAMESPACE}, #{connection.quote(id)})"
        )
      end
    end
  end
end
