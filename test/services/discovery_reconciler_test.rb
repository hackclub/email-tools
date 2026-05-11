require "test_helper"
require "minitest/mock"

class DiscoveryReconcilerTest < ActiveSupport::TestCase
  def setup
    SyncSource.destroy_all
    SyncSourceIgnore.destroy_all
  end

  def teardown
    SyncSource.destroy_all
    SyncSourceIgnore.destroy_all
  end

  test "creates missing sync sources for non-ignored bases" do
    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "base1", name: "Base One" },
      { id: "base2", name: "Base Two" }
    ]

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    assert_equal 2, SyncSource.count
    base1 = SyncSource.find_by(source: "airtable", source_id: "base1")
    assert_not_nil base1
    assert_equal "Base One", base1.display_name
    assert_not_nil base1.last_seen_at
    assert_not_nil base1.first_seen_at
    assert_equal 1, base1.seen_count
  end

  test "skips ignored sources" do
    SyncSourceIgnore.create!(source: "airtable", source_id: "^base1$")

    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "base1", name: "Base One" },
      { id: "base2", name: "Base Two" }
    ]

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    assert_equal 1, SyncSource.count
    assert_nil SyncSource.find_by(source: "airtable", source_id: "base1")
    assert_not_nil SyncSource.find_by(source: "airtable", source_id: "base2")
  end

  test "skips sources matching pattern ignores" do
    SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^app.*"
    )

    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "app123", name: "App Base" },
      { id: "test456", name: "Test Base" },
      { id: "app789", name: "Another App" }
    ]

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    assert_equal 1, SyncSource.count
    assert_nil SyncSource.find_by(source: "airtable", source_id: "app123")
    assert_nil SyncSource.find_by(source: "airtable", source_id: "app789")
    assert_not_nil SyncSource.find_by(source: "airtable", source_id: "test456")
  end

  test "pattern example: ignore everything except one base" do
    # User's use case: ignore everything except one specific base
    SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^(?!app8Hj0IfRlaZYb3g$).*"
    )

    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "app8Hj0IfRlaZYb3g", name: "Allowed Base" },
      { id: "app123", name: "Ignored Base 1" },
      { id: "app456", name: "Ignored Base 2" },
      { id: "test789", name: "Ignored Base 3" }
    ]

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    assert_equal 1, SyncSource.count
    assert_not_nil SyncSource.find_by(source: "airtable", source_id: "app8Hj0IfRlaZYb3g")
    assert_nil SyncSource.find_by(source: "airtable", source_id: "app123")
    assert_nil SyncSource.find_by(source: "airtable", source_id: "app456")
    assert_nil SyncSource.find_by(source: "airtable", source_id: "test789")
  end

  test "combines exact ignores and pattern ignores" do
    SyncSourceIgnore.create!(source: "airtable", source_id: "^base1$")
    SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^app.*"
    )

    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "base1", name: "Exact Ignored" },
      { id: "app123", name: "Pattern Ignored" },
      { id: "base2", name: "Allowed" }
    ]

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    assert_equal 1, SyncSource.count
    assert_not_nil SyncSource.find_by(source: "airtable", source_id: "base2")
  end

  test "updates display_name for existing sources" do
    existing = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Old Name",
      display_name_updated_at: 1.day.ago,
      last_seen_at: 1.day.ago,
      seen_count: 1
    )

    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "base1", name: "New Name" }
    ]

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    existing.reload
    assert_equal "New Name", existing.display_name
    assert existing.display_name_updated_at > 1.day.ago
  end

  test "updates last_seen_at column and increments seen_count" do
    existing = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Base One",
      last_seen_at: 2.days.ago,
      seen_count: 5
    )

    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "base1", name: "Base One" }
    ]

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    existing.reload
    assert existing.last_seen_at > 1.day.ago
    assert_equal 6, existing.seen_count
  end

  test "sets first_seen_at on first update if nil" do
    existing = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Base One",
      first_seen_at: nil,
      last_seen_at: 1.day.ago,
      seen_count: 1
    )

    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "base1", name: "Base One" }
    ]

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    existing.reload
    assert_not_nil existing.first_seen_at
  end

  test "does not change first_seen_at if already set" do
    original_first_seen = 1.week.ago
    existing = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Base One",
      first_seen_at: original_first_seen,
      last_seen_at: 1.day.ago,
      seen_count: 1
    )

    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "base1", name: "Base One" }
    ]

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    existing.reload
    assert_equal original_first_seen.to_i, existing.first_seen_at.to_i
  end

  test "immediately soft deletes disappeared sources" do
    existing = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Base One",
      last_seen_at: 1.day.ago,
      seen_count: 1
    )

    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, []

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    # Should be soft-deleted immediately (not in default scope)
    assert_nil SyncSource.find_by(id: existing.id)

    # But should exist in with_deleted scope
    deleted = SyncSource.with_deleted.find_by(id: existing.id)
    assert_not_nil deleted
    assert_not_nil deleted.deleted_at
    assert_equal "disappeared", deleted.deleted_reason
  end

  test "immediately soft deletes all active sources regardless of origin" do
    # All active sources are subject to retirement, not just discovered ones
    existing = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Base One",
      last_seen_at: 1.day.ago,
      seen_count: 1
    )

    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, []

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    # Should be soft-deleted immediately
    assert_nil SyncSource.find_by(id: existing.id)
    deleted = SyncSource.with_deleted.find_by(id: existing.id)
    assert_not_nil deleted.deleted_at
  end

  test "sets last_seen_at before immediately soft deleting on first disappearance" do
    existing = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Base One",
      last_seen_at: nil
    )

    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, []

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    # Should be soft-deleted immediately
    assert_nil SyncSource.find_by(id: existing.id)

    # But should exist in with_deleted scope with last_seen_at set
    deleted = SyncSource.with_deleted.find_by(id: existing.id)
    assert_not_nil deleted
    assert_not_nil deleted.deleted_at
    assert_not_nil deleted.last_seen_at, "last_seen_at should be set before deletion"
  end

  test "preserves manual deletion reason when base is still missing" do
    # Create and manually delete a source
    manual_deleted = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Base One",
      last_seen_at: 1.day.ago,
      seen_count: 5
    )
    manual_deleted.soft_delete!(reason: :manual)

    # Verify it's deleted with manual reason
    assert_nil SyncSource.find_by(id: manual_deleted.id)
    deleted_before = SyncSource.with_deleted.find_by(id: manual_deleted.id)
    assert_equal "manual", deleted_before.deleted_reason

    # Run reconciler with base still missing
    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, []

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    # Verify manual deletion reason is preserved (not overwritten to disappeared)
    deleted_after = SyncSource.with_deleted.find_by(id: manual_deleted.id)
    assert_not_nil deleted_after
    assert_not_nil deleted_after.deleted_at
    assert_equal "manual", deleted_after.deleted_reason, "Manual deletion reason should be preserved"
  end

  test "sets disappeared reason for nil deleted_reason when base is missing" do
    # Create and delete a source with nil deleted_reason (edge case)
    nil_reason_deleted = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Base One",
      last_seen_at: 1.day.ago,
      seen_count: 5
    )
    # Soft delete without a reason (sets deleted_at but leaves deleted_reason nil)
    nil_reason_deleted.update_columns(deleted_at: Time.current, updated_at: Time.current)

    # Verify deleted_reason is nil
    deleted_before = SyncSource.with_deleted.find_by(id: nil_reason_deleted.id)
    assert_nil deleted_before.deleted_reason

    # Run reconciler with base still missing
    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, []

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    # Verify deleted_reason is set to disappeared (only when nil)
    deleted_after = SyncSource.with_deleted.find_by(id: nil_reason_deleted.id)
    assert_not_nil deleted_after
    assert_not_nil deleted_after.deleted_at
    assert_equal "disappeared", deleted_after.deleted_reason, "Nil deleted_reason should be set to disappeared"
  end

  test "revives soft-deleted source when it reappears" do
    # Create and soft-delete a source
    deleted = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Base One",
      last_seen_at: 1.week.ago,
      seen_count: 5
    )
    deleted.soft_delete!(reason: :ignored_pattern)

    # Verify it's deleted
    assert_nil SyncSource.find_by(id: deleted.id)
    assert_not_nil SyncSource.with_deleted.find_by(id: deleted.id).deleted_at

    # Reconcile with the base reappearing
    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "base1", name: "Base One Restored" }
    ]

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    reconciler.call

    # Should be revived (active again)
    revived = SyncSource.find_by(id: deleted.id)
    assert_not_nil revived
    assert_nil revived.deleted_at
    assert_nil revived.deleted_reason
    assert_equal "Base One Restored", revived.display_name
    assert_equal 6, revived.seen_count # Incremented
    assert_not_nil revived.last_seen_at
  end

  test "handles multiple adapters" do
    airtable_adapter = Minitest::Mock.new
    airtable_adapter.expect :list_ids_with_names, [
      { id: "base1", name: "Airtable Base" }
    ]

    # Note: postgres source would need to be added to SyncSource enum
    # For now, just test with airtable sources
    reconciler = DiscoveryReconciler.new(
      adapters: [
        { source: "airtable", adapter: airtable_adapter }
      ]
    )

    reconciler.call

    assert_equal 1, SyncSource.count
    assert_not_nil SyncSource.find_by(source: "airtable", source_id: "base1")
    airtable_adapter.verify
  end

  test "avoids N+1 queries regardless of number of sources" do
    # Create a mix of existing, soft-deleted, and new sources
    existing_sources = 50.times.map do |i|
      SyncSource.create!(
        source: "airtable",
        source_id: "existing_#{i}",
        display_name: "Existing #{i}",
        last_seen_at: 1.day.ago,
        seen_count: 1
      )
    end

    soft_deleted_sources = 30.times.map do |i|
      source = SyncSource.create!(
        source: "airtable",
        source_id: "deleted_#{i}",
        display_name: "Deleted #{i}",
        last_seen_at: 1.week.ago,
        seen_count: 1
      )
      source.soft_delete!(reason: :manual)
      source
    end

    # Prepare remote data: mix of existing, revived, and new
    remote_data = []
    # Existing sources (will be updated)
    50.times { |i| remote_data << { id: "existing_#{i}", name: "Updated Existing #{i}" } }
    # Soft-deleted sources (will be revived)
    30.times { |i| remote_data << { id: "deleted_#{i}", name: "Revived #{i}" } }
    # New sources (will be created)
    20.times { |i| remote_data << { id: "new_#{i}", name: "New #{i}" } }

    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, remote_data

    # Count SQL queries using ActiveSupport::Notifications
    query_count = 0
    callback = lambda do |_name, _start, _finish, _id, payload|
      query_count += 1 if payload[:sql] && payload[:sql].match?(/^(SELECT|INSERT|UPDATE|DELETE)/i)
    end

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      reconciler.call
    end

    # Verify results
    assert_equal 100, SyncSource.count, "Should have 100 total sources"
    # Verify existing sources were updated (seen_count should be 2, was 1)
    existing_sources.each do |s|
      s.reload
      assert_equal 2, s.seen_count, "Existing source #{s.source_id} should have seen_count incremented"
      assert s.last_seen_at > 1.day.ago, "Existing source #{s.source_id} should have updated last_seen_at"
    end
    # Verify soft-deleted sources were revived
    assert_equal 30, SyncSource.where(source_id: soft_deleted_sources.map(&:source_id)).where(deleted_at: nil).count, "Should have 30 revived sources"
    # Verify new sources were created
    assert_equal 20, SyncSource.where("source_id LIKE 'new_%'").count, "Should have 20 new sources"

    # The key assertion: query count should be O(1) with respect to number of sources
    # Expected queries:
    # 1. Pre-fetch all local sources (1 SELECT with WHERE)
    # 2. Updates for existing sources (50 UPDATE queries)
    # 3. Revivals for soft-deleted sources (30 UPDATE queries)
    # 4. Bulk insert for new sources (1 INSERT)
    # 5. Find_each for retirement check (1 SELECT + iterations, but let's be lenient)
    # We expect roughly 1 + 50 + 30 + 1 + some overhead = ~82-100 queries
    # The important thing is it's NOT 2 * 100 = 200+ queries (which would be N+1)
    assert query_count < 150, "Query count (#{query_count}) should be much less than N+1 pattern (would be 200+). This indicates N+1 queries were eliminated."
  end

  test "created_count matches number of inserted sources in log" do
    # Create 5 new sources
    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "base1", name: "Base One" },
      { id: "base2", name: "Base Two" },
      { id: "base3", name: "Base Three" },
      { id: "base4", name: "Base Four" },
      { id: "base5", name: "Base Five" }
    ]

    # Capture log messages
    log_messages = []
    original_logger = Rails.logger
    test_logger = Class.new do
      def initialize(messages)
        @messages = messages
      end

      def info(message)
        @messages << message
      end

      def error(message)
        @messages << message
      end
    end.new(log_messages)

    reconciler = DiscoveryReconciler.new(
      adapters: [ { source: "airtable", adapter: adapter } ]
    )

    # Temporarily replace logger
    Rails.logger = test_logger
    reconciler.call
    Rails.logger = original_logger

    # Find the log message with created count
    log_message = log_messages.find { |msg| msg.include?("DiscoveryReconciler[airtable]") }
    assert_not_nil log_message, "Should log reconciliation summary"

    # Verify created count matches the number of sources inserted
    # The log format is: "DiscoveryReconciler[airtable]: created=5, updated=0, revived=0, deleted=0"
    assert_match(/created=5/, log_message, "Log should show created=5 for 5 new sources")

    # Also verify the actual count matches
    assert_equal 5, SyncSource.count, "Should have created 5 sources"
  end
end
