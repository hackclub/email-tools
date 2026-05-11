require "test_helper"

class SyncSourceTest < ActiveSupport::TestCase
  def setup
    SyncSource.destroy_all
  end

  test "default_scope hides deleted rows" do
    active = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Active Base"
    )
    deleted = SyncSource.create!(
      source: "airtable",
      source_id: "base2",
      display_name: "Deleted Base"
    )
    deleted.soft_delete!(reason: :manual)

    # Default scope should only show active
    assert_includes SyncSource.all, active
    assert_not_includes SyncSource.all, deleted
  end

  test "with_deleted scope includes deleted rows" do
    active = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Active Base"
    )
    deleted = SyncSource.create!(
      source: "airtable",
      source_id: "base2",
      display_name: "Deleted Base"
    )
    deleted.soft_delete!(reason: :manual)

    all = SyncSource.with_deleted.to_a
    assert_includes all, active
    assert_includes all, deleted
  end

  test "only_deleted scope shows only deleted rows" do
    active = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Active Base"
    )
    deleted = SyncSource.create!(
      source: "airtable",
      source_id: "base2",
      display_name: "Deleted Base"
    )
    deleted.soft_delete!(reason: :manual)

    deleted_only = SyncSource.only_deleted.to_a
    assert_not_includes deleted_only, active
    assert_includes deleted_only, deleted
  end

  test "uniqueness validation only applies to active rows" do
    active = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Active Base"
    )

    # Can't create duplicate active
    duplicate = SyncSource.new(
      source: "airtable",
      source_id: "base1",
      display_name: "Duplicate"
    )
    assert_not duplicate.valid?
    assert duplicate.errors[:source_id].any?

    # Soft delete the first one
    active.soft_delete!(reason: :manual)

    # Now can create new active with same source_id
    new_active = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "New Active"
    )
    assert new_active.persisted?
  end

  test "soft_delete! sets deleted_at and deleted_reason" do
    ss = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Test Base"
    )

    assert_nil ss.deleted_at
    assert_nil ss.deleted_reason

    ss.soft_delete!(reason: :ignored_pattern)

    ss.reload
    assert_not_nil ss.deleted_at
    assert_equal "ignored_pattern", ss.deleted_reason
  end

  test "restore! clears deleted_at and deleted_reason" do
    ss = SyncSource.create!(
      source: "airtable",
      source_id: "base1",
      display_name: "Test Base"
    )
    ss.soft_delete!(reason: :ignored_pattern)

    assert_not_nil ss.deleted_at
    assert_equal "ignored_pattern", ss.deleted_reason

    ss.restore!

    ss.reload
    assert_nil ss.deleted_at
    assert_nil ss.deleted_reason
  end
end
