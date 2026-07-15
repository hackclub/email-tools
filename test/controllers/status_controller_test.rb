require "test_helper"

class StatusControllerTest < ActionDispatch::IntegrationTest
  def setup
    REDIS_FOR_RATE_LIMITING.del(SystemStatus::CACHE_KEY)
  end

  def teardown
    REDIS_FOR_RATE_LIMITING.del(SystemStatus::CACHE_KEY)
  end

  test "internal dashboard renders without any authentication" do
    get internal_dashboard_path

    assert_response :success
    assert_includes @response.body, "System Status"
    assert_includes @response.body, "Airtable polling"
    assert_includes @response.body, "Loops delivery"
  end

  test "internal dashboard exposes json with aggregate metrics" do
    get internal_dashboard_path(format: :json)

    assert_response :success
    body = JSON.parse(@response.body)
    assert_includes %w[ok degraded down unknown], body["verdict"]
    assert body.key?("queues")
    assert body.key?("polling")
    assert body.key?("dispatch")
  end

  test "snapshot contains only aggregate values, never emails" do
    LoopsOutboxEnvelope.create!(
      email_normalized: "someone-private@example.com",
      payload: { "fields" => {} },
      provenance: { "source" => "test" },
      status: "queued",
      sync_source: SyncSource.create!(source: "airtable", source_id: "appStatusTest", poll_interval_seconds: 30)
    )
    REDIS_FOR_RATE_LIMITING.del(SystemStatus::CACHE_KEY)

    get internal_dashboard_path(format: :json)

    assert_response :success
    refute_includes @response.body, "someone-private@example.com",
      "Status payload must never contain email addresses"
  ensure
    LoopsOutboxEnvelope.where(email_normalized: "someone-private@example.com").destroy_all
    SyncSource.where(source_id: "appStatusTest").destroy_all
  end

  test "verdict degrades when queue latency is high" do
    snapshot = {
      "queues" => [ { "name" => "polling", "size" => 10_000, "latency_seconds" => 600.0 } ],
      "workers" => { "processes" => 2 },
      "polling" => { "active_sources" => 100, "stale_sources" => 0 },
      "dispatch" => { "oldest_waiting_seconds" => 0.0 }
    }
    assert_equal "degraded", SystemStatus.verdict_for(snapshot)
  end

  test "verdict is down when no worker processes are alive" do
    snapshot = {
      "queues" => [],
      "workers" => { "processes" => 0 },
      "polling" => { "active_sources" => 100, "stale_sources" => 0 },
      "dispatch" => { "oldest_waiting_seconds" => 0.0 }
    }
    assert_equal "down", SystemStatus.verdict_for(snapshot)
  end
end
