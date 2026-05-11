require "test_helper"
require "minitest/mock"

class PruneLlmCacheWorkerTest < ActiveSupport::TestCase
  def setup
    LlmCache.destroy_all
  end

  def teardown
    LlmCache.destroy_all
  end

  test "deletes entries older than default pruning window" do
    old_entry = LlmCache.create!(
      prompt_hash: "old1",
      request_json: {},
      response_json: { "parsed" => {} },
      bytes_size: 100,
      created_at: 91.days.ago
    )

    recent_entry = LlmCache.create!(
      prompt_hash: "recent1",
      request_json: {},
      response_json: { "parsed" => {} },
      bytes_size: 100,
      created_at: 10.days.ago
    )

    PruneLlmCacheWorker.new.perform

    assert_nil LlmCache.find_by(id: old_entry.id)
    assert_not_nil LlmCache.find_by(id: recent_entry.id)
  end

  test "uses LlmCache.pruning_window_days for cutoff" do
    # Verify it uses the class method
    assert_equal 90, LlmCache.pruning_window_days
    assert_equal 90, LlmCache::DEFAULT_PRUNING_WINDOW_DAYS

    old_entry = LlmCache.create!(
      prompt_hash: "old1",
      request_json: {},
      response_json: { "parsed" => {} },
      bytes_size: 100,
      created_at: 91.days.ago
    )

    PruneLlmCacheWorker.new.perform

    assert_nil LlmCache.find_by(id: old_entry.id)
  end

  test "prunes by size when over limit using LlmCache.max_cache_mb" do
    # Create entries that exceed the limit
    entry_size = 600_000 # 600 KB per entry

    entries = []
    3.times do |i|
      entries << LlmCache.create!(
        prompt_hash: "entry_#{i}",
        request_json: {},
        response_json: { "parsed" => {} },
        bytes_size: entry_size,
        created_at: 10.days.ago,
        last_used_at: (10 - i).days.ago
      )
    end

    # Stub ENV to return a small test limit
    ENV.stub(:fetch, 1, [ "LLM_CACHE_MAX_MB", LlmCache::DEFAULT_MAX_CACHE_MB ]) do
      PruneLlmCacheWorker.new.perform
    end

    # Should have deleted oldest entries until under limit
    remaining_count = LlmCache.count
    assert remaining_count < 3, "Should have pruned entries when over limit"
  end

  test "uses LlmCache.max_cache_mb for size limit" do
    # Verify it uses the class method
    assert_equal 512, LlmCache.max_cache_mb
    assert_equal 512, LlmCache::DEFAULT_MAX_CACHE_MB

    # Create a small entry
    LlmCache.create!(
      prompt_hash: "small1",
      request_json: {},
      response_json: { "parsed" => {} },
      bytes_size: 100,
      created_at: 10.days.ago
    )

    # Should not prune if under limit
    initial_count = LlmCache.count
    PruneLlmCacheWorker.new.perform
    assert_equal initial_count, LlmCache.count, "Should not prune when under limit"
  end

  test "respects ENV override for pruning_window_days" do
    old_entry = LlmCache.create!(
      prompt_hash: "old1",
      request_json: {},
      response_json: { "parsed" => {} },
      bytes_size: 100,
      created_at: 31.days.ago # Would be kept with default 90, but deleted with 30
    )

    ENV.stub(:fetch, "30", [ "LLM_CACHE_PRUNING_WINDOW_DAYS", LlmCache::DEFAULT_PRUNING_WINDOW_DAYS ]) do
      PruneLlmCacheWorker.new.perform
    end

    assert_nil LlmCache.find_by(id: old_entry.id), "Should respect ENV override"
  end

  test "respects ENV override for max_cache_mb" do
    entry_size = 600_000 # 600 KB per entry

    entries = []
    3.times do |i|
      entries << LlmCache.create!(
        prompt_hash: "entry_#{i}",
        request_json: {},
        response_json: { "parsed" => {} },
        bytes_size: entry_size,
        created_at: 10.days.ago,
        last_used_at: (10 - i).days.ago
      )
    end

    # Override with ENV
    ENV.stub(:fetch, "1", [ "LLM_CACHE_MAX_MB", LlmCache::DEFAULT_MAX_CACHE_MB ]) do
      PruneLlmCacheWorker.new.perform
    end

    remaining_count = LlmCache.count
    assert remaining_count < 3, "Should respect ENV override for max_cache_mb"
  end
end
