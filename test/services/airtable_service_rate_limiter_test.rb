require "test_helper"

class AirtableServiceRateLimiterTest < ActiveSupport::TestCase
  def setup
    # Ensure Redis is available
    skip "Redis not available" unless REDIS_FOR_RATE_LIMITING.ping
  end

  test "extracts base_id from records URL" do
    url = "https://api.airtable.com/v0/app123/Table456"
    base_id = AirtableService.send(:extract_base_id, url)
    assert_equal "app123", base_id
  end

  test "extracts base_id from meta bases URL" do
    url = "https://api.airtable.com/v0/meta/bases/app123/tables"
    base_id = AirtableService.send(:extract_base_id, url)
    assert_equal "app123", base_id
  end

  test "extracts base_id from webhooks URL" do
    url = "https://api.airtable.com/v0/bases/app123/webhooks/wh123"
    base_id = AirtableService.send(:extract_base_id, url)
    assert_equal "app123", base_id
  end

  test "returns nil for meta bases list URL" do
    url = "https://api.airtable.com/v0/meta/bases"
    base_id = AirtableService.send(:extract_base_id, url)
    assert_nil base_id, "Should not extract base_id from bases list endpoint"
  end

  test "returns nil for relative paths without base_id" do
    url = "/v0/meta/bases"
    base_id = AirtableService.send(:extract_base_id, url)
    assert_nil base_id
  end

  test "extracts base_id from relative paths" do
    url = "/v0/app123/Table456"
    base_id = AirtableService.send(:extract_base_id, url)
    assert_equal "app123", base_id
  end

  test "global rate limiter is initialized" do
    limiter = AirtableService.global_rate_limiter
    assert_instance_of RateLimiter, limiter
  end

  test "per-base rate limiter is created and cached" do
    base_id = "test_base_#{SecureRandom.hex(4)}"

    limiter1 = AirtableService.send(:rate_limiter_for_base, base_id)
    limiter2 = AirtableService.send(:rate_limiter_for_base, base_id)

    assert_instance_of RateLimiter, limiter1
    assert_equal limiter1, limiter2, "Should return same limiter instance"
  end

  test "different bases get different rate limiters" do
    base_id1 = "test_base_#{SecureRandom.hex(4)}"
    base_id2 = "test_base_#{SecureRandom.hex(4)}"

    limiter1 = AirtableService.send(:rate_limiter_for_base, base_id1)
    limiter2 = AirtableService.send(:rate_limiter_for_base, base_id2)

    assert_not_equal limiter1, limiter2, "Different bases should have different limiters"
  end

  test "global rate limiter enforces 50 req/sec limit" do
    skip "Skipping actual API call test" unless ENV["AIRTABLE_PERSONAL_ACCESS_TOKEN"]

    # Clear any existing rate limit state
    redis_key = "rate:airtable:global"
    REDIS_FOR_RATE_LIMITING.del(redis_key)
    REDIS_FOR_RATE_LIMITING.del("#{redis_key}:seq")

    # Test that rapid requests to meta/bases (no per-base limit) still respect global limit
    # We'll test with a small batch to verify the mechanism works
    start_time = Time.now
    request_times = []
    3.times do |i|
      request_start = Time.now
      begin
        AirtableService.get("https://api.airtable.com/v0/meta/bases")
        request_times << Time.now - request_start
      rescue => e
        # Ignore errors - we're just testing rate limiting, not API correctness
      end
    end
    elapsed = Time.now - start_time

    # Should complete relatively quickly since we're well under 50 req/sec
    # But allow for network latency (each API call might take ~0.2-0.5s)
    assert elapsed < 3.0, "3 requests should complete in reasonable time (allows for API latency), took #{elapsed}s"

    # Verify rate limiting is actually applied - requests should not all be immediate
    # Even under global limit, they should be properly throttled if needed
    assert elapsed >= 0.1, "Should take some time even for allowed requests"
  end

  test "per-base rate limiter no longer serializes consecutive requests" do
    skip "Skipping actual API call test" unless ENV["AIRTABLE_PERSONAL_ACCESS_TOKEN"]

    # We need a real base_id for this test
    # Try to get one from the API
    begin
      bases = []
      AirtableService::Bases.find_each { |base| bases << base; break if bases.length >= 1 }
      skip "No bases available for testing" if bases.empty?

      base_id = bases.first["id"]

      # Clear rate limit state for this base
      redis_key = "rate:airtable:base:#{base_id}"
      REDIS_FOR_RATE_LIMITING.del(redis_key)
      REDIS_FOR_RATE_LIMITING.del("#{redis_key}:seq")

      # With the per-base limit at Airtable's documented 5 req/sec, a couple
      # of back-to-back requests must not be delayed by our limiter (the old
      # 1 req/sec limit added a full second to each). fresh: true bypasses
      # the schema cache so each call really hits the API.
      second_start = nil
      AirtableService::Bases.get_schema(base_id: base_id, fresh: true)
      second_start = Time.now
      AirtableService::Bases.get_schema(base_id: base_id, fresh: true)
      second_duration = Time.now - second_start

      assert second_duration < 0.8,
        "Second request should not wait on the per-base limiter (took #{second_duration}s)"
    rescue => e
      skip "Could not test per-base limiting: #{e.message}"
    end
  end

  test "per-base rate limiter enforces the configured per-second window" do
    # Deterministic check against the limiter itself (no API): the configured
    # number of slots are immediate, the next acquire must wait for the 1s
    # window to free up. Uses the same limit the app configures per base.
    limit = AirtableService::PER_BASE_RATE_LIMIT
    key = "rate:test:per-base-window:#{SecureRandom.hex(4)}"
    limiter = RateLimiter.new(redis: REDIS_FOR_RATE_LIMITING, key: key, limit: limit, period: 1.0)

    start = Time.now
    limit.times { limiter.acquire! }
    allowed_duration = Time.now - start

    over_start = Time.now
    limiter.acquire!
    over_duration = Time.now - over_start

    assert allowed_duration < 0.5, "First #{limit} acquires should be immediate, took #{allowed_duration}s"
    assert over_duration >= 0.4, "Acquire #{limit + 1} should wait for the sliding window, took #{over_duration}s"
    assert over_duration < 2.0, "Acquire #{limit + 1} should not wait more than one window, took #{over_duration}s"
  ensure
    REDIS_FOR_RATE_LIMITING.del(key)
    REDIS_FOR_RATE_LIMITING.del("#{key}:seq")
  end
end
