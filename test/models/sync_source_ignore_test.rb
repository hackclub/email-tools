require "test_helper"

class SyncSourceIgnoreTest < ActiveSupport::TestCase
  def setup
    SyncSourceIgnore.destroy_all
  end

  test "validates presence of source" do
    ignore = SyncSourceIgnore.new(source_id: "base123")
    assert_not ignore.valid?
    assert_includes ignore.errors[:source], "can't be blank"
  end

  test "validates presence of source_id" do
    ignore = SyncSourceIgnore.new(source: "airtable")
    assert_not ignore.valid?
    assert_includes ignore.errors[:source_id], "can't be blank"
  end

  test "creates valid ignore record" do
    ignore = SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^base123$"
    )
    assert ignore.persisted?
    assert_equal "airtable", ignore.source
    assert_equal "^base123$", ignore.source_id
  end

  test "allows optional reason" do
    ignore = SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^base123$",
      reason: "Development base"
    )
    assert_equal "Development base", ignore.reason
  end

  test "enforces unique constraint on source and source_id" do
    SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^base123$"
    )

    duplicate = SyncSourceIgnore.new(
      source: "airtable",
      source_id: "^base123$"
    )
    assert_not duplicate.valid?
    assert duplicate.errors[:source_id].any?, "Should have uniqueness error on source_id"
  end

  test "allows same source_id for different sources" do
    SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^base123$"
    )

    different_source = SyncSourceIgnore.create!(
      source: "postgres",
      source_id: "^base123$"
    )
    assert different_source.persisted?
  end

  test "source_id is always treated as regex pattern" do
    ignore = SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^app.*"
    )
    assert ignore.matches?("app123")
    assert ignore.matches?("appTest")
    assert_not ignore.matches?("test123")
  end

  test "exact matches use anchored regex" do
    ignore = SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^base123$"
    )
    assert ignore.matches?("base123")
    assert_not ignore.matches?("base1234")
    assert_not ignore.matches?("base123extra")
  end

  test "validates source_id is valid regex" do
    ignore = SyncSourceIgnore.new(
      source: "airtable",
      source_id: "[invalid"
    )
    assert_not ignore.valid?
    assert ignore.errors[:source_id].any?
  end

  test "handles invalid regex gracefully in matches?" do
    ignore = SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^app.*"
    )
    # Manually corrupt the source_id to test error handling
    ignore.update_column(:source_id, "[invalid")
    assert_not ignore.matches?("app123")
  end

  test "pattern example: ignore everything except one base" do
    # This is the use case the user mentioned
    ignore = SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^(?!app8Hj0IfRlaZYb3g$).*"
    )
    assert_not ignore.matches?("app8Hj0IfRlaZYb3g")
    assert ignore.matches?("app123")
    assert ignore.matches?("appTest")
    assert ignore.matches?("anything")
  end

  test "allows multiple patterns for same source" do
    SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^app.*"
    )
    other_pattern = SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^test.*"
    )
    assert other_pattern.persisted?
  end

  test "rejects patterns longer than MAX_PATTERN_LENGTH" do
    long_pattern = "a" * (SyncSourceIgnore::MAX_PATTERN_LENGTH + 1)
    ignore = SyncSourceIgnore.new(
      source: "airtable",
      source_id: long_pattern
    )
    assert_not ignore.valid?
    assert ignore.errors[:source_id].any?
    assert_match(/too long/, ignore.errors[:source_id].first)
  end

  test "matches? returns false for patterns longer than MAX_PATTERN_LENGTH" do
    long_pattern = "a" * (SyncSourceIgnore::MAX_PATTERN_LENGTH + 1)
    # Create with valid pattern first, then update to bypass validation
    ignore = SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^test$"
    )
    # Manually set to bypass validation for this test
    ignore.update_column(:source_id, long_pattern)

    assert_not ignore.matches?("test")
  end

  test "matches? times out on pathological regex patterns" do
    # Catastrophic backtracking pattern: (a+)+$
    pathological_pattern = "(a+)+$"
    ignore = SyncSourceIgnore.create!(
      source: "airtable",
      source_id: pathological_pattern
    )

    # Test with a string that causes backtracking
    # This should timeout quickly and return false
    result = ignore.matches?("a" * 50 + "b")
    assert_equal false, result, "Pathological regex should timeout and return false"
  end

  test "matches? handles timeout gracefully" do
    # Another pathological pattern: nested quantifiers
    pathological_pattern = "(a*)*b"
    ignore = SyncSourceIgnore.create!(
      source: "airtable",
      source_id: pathological_pattern
    )

    # This should timeout quickly
    result = ignore.matches?("a" * 100)
    assert_equal false, result, "Should timeout and return false"
  end

  test "database enforces NOT NULL constraint on source" do
    # Test that database-level constraint prevents NULL source
    assert_raises(ActiveRecord::NotNullViolation) do
      SyncSourceIgnore.connection.execute(
        "INSERT INTO sync_source_ignores (source, source_id, created_at, updated_at) VALUES (NULL, 'test', NOW(), NOW())"
      )
    end
  end

  test "database enforces NOT NULL constraint on source_id" do
    # Test that database-level constraint prevents NULL source_id
    assert_raises(ActiveRecord::NotNullViolation) do
      SyncSourceIgnore.connection.execute(
        "INSERT INTO sync_source_ignores (source, source_id, created_at, updated_at) VALUES ('airtable', NULL, NOW(), NOW())"
      )
    end
  end
end
