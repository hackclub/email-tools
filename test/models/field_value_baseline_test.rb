require "test_helper"

class FieldValueBaselineTest < ActiveSupport::TestCase
  def setup
    @sync_source = SyncSource.create!(
      source: "airtable",
      source_id: "app123",
      poll_interval_seconds: 30
    )
    @row_id = "tbl123_rec456"
    @field_id = "fld789"
  end

  def teardown
    FieldValueBaseline.destroy_all
    LoopsOutboxEnvelope.destroy_all  # Destroy envelopes before sync_sources
    SyncSource.destroy_all
  end

  test "detect_change creates baseline on first time" do
    current_value = "Hello World"
    result = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: current_value
    )

    assert result[:first_time], "Should indicate first time"
    assert result[:changed], "First time should be considered a change"
    assert result[:baseline].persisted?, "Baseline should be persisted"
    assert_equal @sync_source.id, result[:baseline].sync_source_id
    assert_equal @row_id, result[:baseline].row_id
    assert_equal @field_id, result[:baseline].field_id
    assert_equal current_value, result[:baseline].last_known_value
    assert_not_nil result[:baseline].last_checked_at
    assert_not_nil result[:baseline].value_last_updated_at
    assert_nil result[:old_value], "old_value should be nil on first time"
  end

  test "detect_change marks first time nil value as changed" do
    result = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: nil
    )

    assert result[:first_time], "Should indicate first time"
    assert result[:changed], "First time with nil should be considered a change"
    assert result[:baseline].persisted?, "Baseline should be persisted"
    assert_nil result[:baseline].last_known_value
    assert_nil result[:old_value], "old_value should be nil on first time"
  end

  test "detect_change detects value change" do
    initial_value = "Hello"
    changed_value = "World"

    # First detection
    result1 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: initial_value
    )
    assert result1[:first_time]
    assert_nil result1[:old_value], "old_value should be nil on first time"

    # Second detection with different value
    result2 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: changed_value
    )

    refute result2[:first_time], "Should not be first time"
    assert result2[:changed], "Should detect change"
    assert_equal changed_value, result2[:baseline].last_known_value
    assert_equal result1[:baseline].id, result2[:baseline].id, "Should be same baseline record"
    assert_equal initial_value, result2[:old_value], "old_value should be the previous value"
  end

  test "detect_change does not report change when value is same" do
    value = "Hello World"

    # First detection
    FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: value
    )

    # Second detection with same value
    result = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: value
    )

    refute result[:changed], "Should not detect change for same value"
    assert_equal value, result[:baseline].last_known_value
    assert_equal value, result[:old_value], "old_value should be the previous value even when unchanged"
  end

  test "detect_change handles nil values correctly" do
    # First detection with nil
    result1 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: nil
    )
    assert result1[:first_time]
    assert_nil result1[:baseline].last_known_value
    assert_nil result1[:old_value], "old_value should be nil on first time"

    # Second detection with nil (should not be a change)
    result2 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: nil
    )
    refute result2[:changed], "Nil to nil should not be a change"
    assert_nil result2[:old_value], "old_value should be nil (previous value was nil)"

    # Third detection with actual value (should be a change)
    result3 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: "Hello"
    )
    assert result3[:changed], "Nil to value should be a change"
    assert_equal "Hello", result3[:baseline].last_known_value
    assert_nil result3[:old_value], "old_value should be nil (previous value was nil)"

    # Fourth detection back to nil (should be a change)
    result4 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: nil
    )
    assert result4[:changed], "Value to nil should be a change"
    assert_nil result4[:baseline].last_known_value
    assert_equal "Hello", result4[:old_value], "old_value should be 'Hello' (previous value)"
  end

  test "detect_change handles hash values" do
    hash_value = { "name" => "John", "age" => 30 }

    result1 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: hash_value
    )
    assert result1[:first_time]

    # Same hash (should not change)
    result2 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: hash_value.dup
    )
    refute result2[:changed], "Same hash should not be a change"

    # Different hash (should change)
    changed_hash = { "name" => "Jane", "age" => 25 }
    result3 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: changed_hash
    )
    assert result3[:changed], "Different hash should be a change"
  end

  test "detect_change handles array values" do
    array_value = [ "item1", "item2", "item3" ]

    result1 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: array_value
    )
    assert result1[:first_time]

    # Same array (should not change)
    result2 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: array_value.dup
    )
    refute result2[:changed], "Same array should not be a change"

    # Different array (should change)
    changed_array = [ "item4", "item5" ]
    result3 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: changed_array
    )
    assert result3[:changed], "Different array should be a change"
  end

  test "detect_change updates last_checked_at every time" do
    value = "Hello"

    result1 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: value,
      checked_at: Time.parse("2024-01-01 10:00:00 UTC")
    )
    first_checked = result1[:baseline].last_checked_at

    sleep(0.1) # Small delay to ensure different timestamp

    result2 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: value,
      checked_at: Time.parse("2024-01-01 10:01:00 UTC")
    )
    second_checked = result2[:baseline].last_checked_at

    assert second_checked > first_checked, "last_checked_at should update even when value doesn't change"
  end

  test "detect_change increments checked_count" do
    value = "Hello"

    result1 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: value
    )
    first_count = result1[:baseline].checked_count

    result2 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: value
    )
    second_count = result2[:baseline].checked_count

    assert_equal first_count + 1, second_count, "checked_count should increment"
  end

  test "detect_change canonicalizes hash keys" do
    # Hash with symbol keys
    hash_with_symbols = { name: "John", age: 30 }

    result1 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: hash_with_symbols
    )

    # Same hash with string keys (should be treated as same)
    hash_with_strings = { "name" => "John", "age" => 30 }
    result2 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: hash_with_strings
    )

    refute result2[:changed], "Hash with symbol keys vs string keys should normalize to same value"
  end

  test "detect_change handles multiple sync sources independently" do
    sync_source2 = SyncSource.create!(
      source: "airtable",
      source_id: "app456",
      poll_interval_seconds: 30
    )

    value = "Hello"

    # Create baseline for first sync source
    result1 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: value
    )

    # Create baseline for second sync source with same row_id and field_id
    result2 = FieldValueBaseline.detect_change(
      sync_source: sync_source2,
      row_id: @row_id,
      field_id: @field_id,
      current_value: value
    )

    assert result1[:baseline].id != result2[:baseline].id, "Should create separate baselines for different sync sources"
    assert_equal @sync_source.id, result1[:baseline].sync_source_id
    assert_equal sync_source2.id, result2[:baseline].sync_source_id
  end

  test "prune_stale removes baselines older than cutoff" do
    cutoff_time = Time.parse("2024-01-01 12:00:00 UTC")
    stale_time = Time.parse("2024-01-01 10:00:00 UTC") # 2 hours before cutoff
    recent_time = Time.parse("2024-01-01 13:00:00 UTC") # 1 hour after cutoff

    # Create stale baseline
    baseline1 = FieldValueBaseline.create!(
      sync_source: @sync_source,
      row_id: "tbl1_rec1",
      field_id: "fld1",
      last_known_value: "value1",
      last_checked_at: stale_time,
      value_last_updated_at: stale_time
    )

    # Create recent baseline
    baseline2 = FieldValueBaseline.create!(
      sync_source: @sync_source,
      row_id: "tbl1_rec2",
      field_id: "fld2",
      last_known_value: "value2",
      last_checked_at: recent_time,
      value_last_updated_at: recent_time
    )

    # Prune stale entries
    FieldValueBaseline.prune_stale(older_than: cutoff_time)

    # Verify stale baseline is deleted
    refute FieldValueBaseline.exists?(baseline1.id), "Stale baseline should be deleted"

    # Verify recent baseline still exists
    assert FieldValueBaseline.exists?(baseline2.id), "Recent baseline should not be deleted"
  end

  test "prune_stale returns count of deleted records" do
    cutoff_time = Time.parse("2024-01-01 12:00:00 UTC")
    stale_time = Time.parse("2024-01-01 10:00:00 UTC")

    # Create multiple stale baselines
    3.times do |i|
      FieldValueBaseline.create!(
        sync_source: @sync_source,
        row_id: "tbl1_rec#{i}",
        field_id: "fld1",
        last_known_value: "value#{i}",
        last_checked_at: stale_time,
        value_last_updated_at: stale_time
      )
    end

    deleted_count = FieldValueBaseline.prune_stale(older_than: cutoff_time)
    assert_equal 3, deleted_count, "Should return count of deleted records"
  end

  test "stale_before scope filters correctly" do
    cutoff_time = Time.parse("2024-01-01 12:00:00 UTC")
    stale_time = Time.parse("2024-01-01 10:00:00 UTC")
    recent_time = Time.parse("2024-01-01 13:00:00 UTC")

    baseline1 = FieldValueBaseline.create!(
      sync_source: @sync_source,
      row_id: "tbl1_rec1",
      field_id: "fld1",
      last_known_value: "value1",
      last_checked_at: stale_time,
      value_last_updated_at: stale_time
    )

    baseline2 = FieldValueBaseline.create!(
      sync_source: @sync_source,
      row_id: "tbl1_rec2",
      field_id: "fld2",
      last_known_value: "value2",
      last_checked_at: recent_time,
      value_last_updated_at: recent_time
    )

    stale_baselines = FieldValueBaseline.stale_before(cutoff_time)
    assert stale_baselines.include?(baseline1), "Should include stale baseline"
    refute stale_baselines.include?(baseline2), "Should not include recent baseline"
  end

  test "validates presence of required fields" do
    baseline = FieldValueBaseline.new
    refute baseline.valid?, "Should not be valid without required fields"

    assert baseline.errors[:sync_source_id].any?, "Should have error for sync_source_id"
    assert baseline.errors[:row_id].any?, "Should have error for row_id"
    assert baseline.errors[:field_id].any?, "Should have error for field_id"
    assert baseline.errors[:last_checked_at].any?, "Should have error for last_checked_at"
  end

  test "belongs_to sync_source" do
    baseline = FieldValueBaseline.create!(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      last_known_value: "test",
      last_checked_at: Time.current,
      value_last_updated_at: Time.current
    )

    assert_equal @sync_source, baseline.sync_source
  end

  test "detect_change always includes old_value in result" do
    # First call - old_value should be nil
    result1 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: "first"
    )

    assert result1.key?(:old_value), "Result should always include old_value key"
    assert_nil result1[:old_value], "old_value should be nil on first time"

    # Second call - old_value should be "first"
    result2 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: "second"
    )

    assert result2.key?(:old_value), "Result should always include old_value key"
    assert_equal "first", result2[:old_value], "old_value should match previous value"
    assert_equal "first", result1[:baseline].last_known_value, "old_value should match previous baseline's last_known_value"

    # Third call - old_value should be "second"
    result3 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: "third"
    )

    assert result3.key?(:old_value), "Result should always include old_value key"
    assert_equal "second", result3[:old_value], "old_value should chain correctly through multiple changes"
  end

  test "detect_change old_value matches previous baseline value even when unchanged" do
    value = "consistent"

    # First call
    result1 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: value
    )
    assert_nil result1[:old_value]

    # Second call with same value - old_value should still be the previous value
    result2 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: value
    )
    assert_equal value, result2[:old_value], "old_value should be present even when value doesn't change"
    refute result2[:changed], "Should not be marked as changed"

    # Third call with same value again
    result3 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: value
    )
    assert_equal value, result3[:old_value], "old_value should still be the same value"
  end

  test "detect_change old_value tracks changes through complex sequences" do
    # Test a sequence: nil -> value -> nil -> different value -> same value
    values = [ nil, "first", nil, "second", "second" ]
    expected_old_values = [ nil, nil, "first", nil, "second" ]

    values.each_with_index do |current_value, index|
      result = FieldValueBaseline.detect_change(
        sync_source: @sync_source,
        row_id: @row_id,
        field_id: @field_id,
        current_value: current_value
      )

      expected_old = expected_old_values[index]
      if expected_old.nil?
        assert_nil result[:old_value],
          "old_value at step #{index + 1} should be nil, got #{result[:old_value].inspect}"
      else
        assert_equal expected_old, result[:old_value],
          "old_value at step #{index + 1} should be #{expected_old.inspect}, got #{result[:old_value].inspect}"
      end
    end
  end

  test "detect_change old_value works with complex data types" do
    # Test with hash
    hash1 = { "key" => "value1" }
    hash2 = { "key" => "value2" }

    result1 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: hash1
    )
    assert_nil result1[:old_value]

    result2 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: @row_id,
      field_id: @field_id,
      current_value: hash2
    )
    assert_equal hash1, result2[:old_value], "old_value should work with hash values"

    # Test with array
    array1 = [ 1, 2, 3 ]
    array2 = [ 4, 5, 6 ]

    result3 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: "tbl2_rec2",
      field_id: @field_id,
      current_value: array1
    )
    assert_nil result3[:old_value]

    result4 = FieldValueBaseline.detect_change(
      sync_source: @sync_source,
      row_id: "tbl2_rec2",
      field_id: @field_id,
      current_value: array2
    )
    assert_equal array1, result4[:old_value], "old_value should work with array values"
  end

  test "detect_changes_batch handles new, changed, and unchanged checks in one call" do
    FieldValueBaseline.detect_change(
      sync_source: @sync_source, row_id: "tbl1_rec1", field_id: "fldA", current_value: "same"
    )
    FieldValueBaseline.detect_change(
      sync_source: @sync_source, row_id: "tbl1_rec2", field_id: "fldA", current_value: "before"
    )

    results = FieldValueBaseline.detect_changes_batch(
      sync_source: @sync_source,
      checks: [
        { row_id: "tbl1_rec1", field_id: "fldA", current_value: "same" },
        { row_id: "tbl1_rec2", field_id: "fldA", current_value: "after" },
        { row_id: "tbl1_rec3", field_id: "fldA", current_value: "brand new" }
      ]
    )

    unchanged = results[[ "tbl1_rec1", "fldA" ]]
    refute unchanged[:changed], "Unchanged value should not be flagged"
    refute unchanged[:first_time]
    assert_equal "same", unchanged[:old_value]

    changed = results[[ "tbl1_rec2", "fldA" ]]
    assert changed[:changed], "Changed value should be flagged"
    refute changed[:first_time]
    assert_equal "before", changed[:old_value]

    first_time = results[[ "tbl1_rec3", "fldA" ]]
    assert first_time[:changed], "First time should be considered a change"
    assert first_time[:first_time]
    assert_nil first_time[:old_value]

    assert_equal "after",
      FieldValueBaseline.find_by(sync_source_id: @sync_source.id, row_id: "tbl1_rec2", field_id: "fldA").last_known_value
    new_baseline = FieldValueBaseline.find_by(sync_source_id: @sync_source.id, row_id: "tbl1_rec3", field_id: "fldA")
    assert_equal "brand new", new_baseline.last_known_value
    assert_equal 1, new_baseline.checked_count
  end

  test "detect_changes_batch bumps bookkeeping without touching value timestamps on unchanged rows" do
    first = FieldValueBaseline.detect_change(
      sync_source: @sync_source, row_id: @row_id, field_id: @field_id, current_value: "stable"
    )[:baseline]
    original_value_updated_at = first.value_last_updated_at
    original_checked_at = first.last_checked_at
    original_count = first.checked_count

    FieldValueBaseline.detect_changes_batch(
      sync_source: @sync_source,
      checks: [ { row_id: @row_id, field_id: @field_id, current_value: "stable" } ],
      checked_at: original_checked_at + 10.seconds
    )

    reloaded = first.reload
    assert_equal original_count + 1, reloaded.checked_count, "checked_count should increment"
    assert reloaded.last_checked_at > original_checked_at, "last_checked_at should advance"
    assert_equal original_value_updated_at, reloaded.value_last_updated_at,
      "value_last_updated_at should not move when the value is unchanged"
    assert_equal "stable", reloaded.last_known_value
  end

  test "detect_changes_batch collapses duplicate row and field pairs with last value winning" do
    results = FieldValueBaseline.detect_changes_batch(
      sync_source: @sync_source,
      checks: [
        { row_id: @row_id, field_id: @field_id, current_value: "first" },
        { row_id: @row_id, field_id: @field_id, current_value: "second" }
      ]
    )

    assert_equal 1, results.size
    assert results[[ @row_id, @field_id ]][:first_time]
    assert_equal "second",
      FieldValueBaseline.find_by(sync_source_id: @sync_source.id, row_id: @row_id, field_id: @field_id).last_known_value
  end

  test "detect_changes_batch returns empty hash for empty checks" do
    assert_equal({}, FieldValueBaseline.detect_changes_batch(sync_source: @sync_source, checks: []))
  end

  test "detect_changes_batch uses a bounded number of queries" do
    10.times do |i|
      FieldValueBaseline.detect_change(
        sync_source: @sync_source, row_id: "tblq_rec#{i}", field_id: "fldQ", current_value: "v#{i}"
      )
    end

    checks = []
    10.times { |i| checks << { row_id: "tblq_rec#{i}", field_id: "fldQ", current_value: (i.even? ? "v#{i}" : "changed") } }
    10.times { |i| checks << { row_id: "tblq_new#{i}", field_id: "fldQ", current_value: "new" } }

    query_count = 0
    counter = lambda do |_name, _start, _finish, _id, payload|
      next if %w[SCHEMA TRANSACTION].include?(payload[:name])
      next if payload[:sql] =~ /\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/i
      query_count += 1
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      FieldValueBaseline.detect_changes_batch(sync_source: @sync_source, checks: checks)
    end

    assert_operator query_count, :<=, 4,
      "Batch detection should use a constant number of statements (SELECT + bulk UPDATE + upsert), got #{query_count}"
  end
end
