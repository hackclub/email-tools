require "sidekiq/api"

# Aggregated, privacy-safe health snapshot for the public status page.
# Everything here is counts and durations — never emails, source names,
# record data, or anything else identifying.
class SystemStatus
  CACHE_KEY = "cache:system_status"
  CACHE_TTL_SECONDS = 15

  # How stale a source's last successful poll may be before it counts
  # against system health (well above the 30s poll interval).
  SOURCE_STALE_AFTER_SECONDS = 600

  QUEUE_LATENCY_DEGRADED_SECONDS = 300
  QUEUE_LATENCY_DOWN_SECONDS = 1800
  ENVELOPE_WAIT_DEGRADED_SECONDS = 900
  ENVELOPE_WAIT_DOWN_SECONDS = 3600

  def self.snapshot
    cached = REDIS_FOR_RATE_LIMITING.get(CACHE_KEY)
    if cached
      parsed = JSON.parse(cached) rescue nil
      return parsed if parsed
    end

    fresh = compute
    REDIS_FOR_RATE_LIMITING.set(CACHE_KEY, JSON.generate(fresh), ex: CACHE_TTL_SECONDS)
    fresh
  rescue => e
    Rails.logger.error("SystemStatus: failed to build snapshot: #{e.class}")
    { "verdict" => "unknown", "generated_at" => Time.current.utc.iso8601 }
  end

  def self.compute
    now = Time.current

    queues = Sidekiq::Queue.all.map do |q|
      { "name" => q.name, "size" => q.size, "latency_seconds" => q.latency.round(1) }
    end
    stats = Sidekiq::Stats.new
    processes = Sidekiq::ProcessSet.new.size

    active_sources = SyncSource.where(deleted_at: nil)
    total_sources = active_sources.count
    polled_2m = active_sources.where("last_successful_poll_at > ?", now - 2.minutes).count
    stale_sources = active_sources.where(
      "last_successful_poll_at IS NULL OR last_successful_poll_at < ?", now - SOURCE_STALE_AFTER_SECONDS.seconds
    ).count
    failing_sources = active_sources.where("consecutive_failures >= 3").count

    queued_envelopes = LoopsOutboxEnvelope.where(status: "queued")
    oldest_queued_at = queued_envelopes.minimum(:created_at)
    oldest_queued_age = oldest_queued_at ? (now - oldest_queued_at).round(1) : 0.0

    delivery_row = LoopsOutboxEnvelope.connection.select_one(<<~SQL)
      SELECT
        count(*) AS delivered_last_hour,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM updated_at - created_at)) AS median_seconds,
        percentile_cont(0.95) WITHIN GROUP (ORDER BY extract(epoch FROM updated_at - created_at)) AS p95_seconds
      FROM loops_outbox_envelopes
      WHERE status IN ('sent', 'partially_sent', 'ignored_noop')
        AND updated_at > now() - interval '1 hour'
    SQL

    created_last_hour = LoopsOutboxEnvelope.where("created_at > ?", now - 1.hour).count
    failed_last_hour = LoopsOutboxEnvelope.where(status: "failed").where("updated_at > ?", now - 1.hour).count

    snapshot = {
      "generated_at" => now.utc.iso8601,
      "queues" => queues,
      "workers" => { "processes" => processes, "busy_threads" => stats.workers_size },
      "retry_size" => stats.retry_size,
      "dead_size" => stats.dead_size,
      "polling" => {
        "active_sources" => total_sources,
        "polled_within_2m" => polled_2m,
        "stale_sources" => stale_sources,
        "failing_sources" => failing_sources
      },
      "dispatch" => {
        "envelopes_created_last_hour" => created_last_hour,
        "envelopes_waiting" => queued_envelopes.count,
        "oldest_waiting_seconds" => oldest_queued_age,
        "delivered_last_hour" => delivery_row["delivered_last_hour"].to_i,
        "failed_last_hour" => failed_last_hour,
        "median_delivery_seconds" => delivery_row["median_seconds"]&.to_f&.round(1),
        "p95_delivery_seconds" => delivery_row["p95_seconds"]&.to_f&.round(1)
      }
    }

    snapshot["verdict"] = verdict_for(snapshot)
    snapshot
  end

  def self.verdict_for(snapshot)
    worst_latency = snapshot["queues"].map { |q| q["latency_seconds"].to_f }.max || 0.0
    oldest_wait = snapshot.dig("dispatch", "oldest_waiting_seconds").to_f
    total = snapshot.dig("polling", "active_sources").to_i
    stale = snapshot.dig("polling", "stale_sources").to_i
    stale_ratio = total.positive? ? stale.to_f / total : 0.0
    processes = snapshot.dig("workers", "processes").to_i

    return "down" if processes.zero?
    return "down" if worst_latency > QUEUE_LATENCY_DOWN_SECONDS
    return "down" if oldest_wait > ENVELOPE_WAIT_DOWN_SECONDS
    return "down" if stale_ratio > 0.5

    return "degraded" if worst_latency > QUEUE_LATENCY_DEGRADED_SECONDS
    return "degraded" if oldest_wait > ENVELOPE_WAIT_DEGRADED_SECONDS
    return "degraded" if stale_ratio > 0.05

    "ok"
  end
end
