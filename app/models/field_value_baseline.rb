class FieldValueBaseline < ApplicationRecord
  belongs_to :sync_source

  validates :sync_source_id, :row_id, :field_id, :last_checked_at, presence: true

  scope :stale_before, ->(time) { where("last_checked_at < ?", time) }
  scope :for_sync_source, ->(source) { where(sync_source_id: source.id) }

  # One-shot detect + persist (baseline on first see; update if changed)
  #
  # @param sync_source [SyncSource] The sync source this baseline belongs to
  # @param row_id [String] Combined table_id and record_id (e.g., "tbl123_rec456")
  # @param field_id [String] The Airtable field ID
  # @param current_value [Object] The current field value from Airtable
  # @param checked_at [Time] When this check occurred (defaults to Time.current)
  # @return [Hash] Returns { baseline:, changed:, first_time:, old_value: }
  #   - baseline: The FieldValueBaseline record (persisted)
  #   - changed: Boolean indicating if value changed from last known value
  #   - first_time: Boolean indicating if this is the first time seeing this row+field
  #   - old_value: The previous value before this update (nil if first_time)
  def self.detect_change(sync_source:, row_id:, field_id:, current_value:, checked_at: Time.current)
    results = detect_changes_batch(
      sync_source: sync_source,
      checks: [ { row_id: row_id, field_id: field_id, current_value: current_value } ],
      checked_at: checked_at
    )
    result = results[[ row_id, field_id ]]
    baseline = find_by!(sync_source_id: sync_source.id, row_id: row_id, field_id: field_id)

    { baseline: baseline, changed: result[:changed], first_time: result[:first_time], old_value: result[:old_value] }
  end

  # Batch variant of detect_change: detects and persists all checks for one
  # sync source in three statements (one SELECT, one bulk bookkeeping UPDATE
  # for unchanged rows, one upsert for new/changed rows) instead of a
  # SELECT + UPDATE per row+field. Polls check every Loops field of every
  # fetched record each cycle, so the per-check writes of the one-shot API
  # dominated poll time on large tables.
  #
  # @param sync_source [SyncSource] The sync source these baselines belong to
  # @param checks [Array<Hash>] Hashes with :row_id, :field_id, :current_value.
  #   Duplicate row+field pairs are collapsed (last one wins).
  # @param checked_at [Time] When this check occurred (defaults to Time.current)
  # @return [Hash] Keyed by [row_id, field_id], each value
  #   { changed:, first_time:, old_value: } with the same semantics as
  #   detect_change.
  def self.detect_changes_batch(sync_source:, checks:, checked_at: Time.current)
    deduped = {}
    checks.each { |check| deduped[[ check[:row_id], check[:field_id] ]] = check[:current_value] }
    return {} if deduped.empty?

    existing = where(sync_source_id: sync_source.id, row_id: deduped.keys.map(&:first).uniq)
                 .index_by { |bl| [ bl.row_id, bl.field_id ] }

    results = {}
    upsert_rows = []
    unchanged_ids = []

    deduped.each do |(row_id, field_id), current_value|
      baseline = existing[[ row_id, field_id ]]
      canonical_value = canonicalize_value(current_value)

      if baseline.nil?
        results[[ row_id, field_id ]] = { changed: true, first_time: true, old_value: nil }
        upsert_rows << {
          sync_source_id: sync_source.id,
          row_id: row_id,
          field_id: field_id,
          last_known_value: canonical_value,
          value_last_updated_at: checked_at,
          last_checked_at: checked_at,
          first_seen_at: checked_at,
          checked_count: 1
        }
      elsif canonical_value.to_json != canonicalize_value(baseline.last_known_value).to_json
        results[[ row_id, field_id ]] = { changed: true, first_time: false, old_value: baseline.last_known_value }
        upsert_rows << {
          sync_source_id: sync_source.id,
          row_id: row_id,
          field_id: field_id,
          last_known_value: canonical_value,
          value_last_updated_at: checked_at,
          last_checked_at: checked_at,
          first_seen_at: baseline.first_seen_at || checked_at,
          checked_count: (baseline.checked_count || 0) + 1
        }
      else
        results[[ row_id, field_id ]] = { changed: false, first_time: false, old_value: baseline.last_known_value }
        unchanged_ids << baseline.id
      end
    end

    if unchanged_ids.any?
      # Rails also touches updated_at in update_all here (Rails 8 behavior),
      # matching the save! the one-shot API used to do.
      where(id: unchanged_ids).update_all(
        [ "checked_count = checked_count + 1, last_checked_at = ?", checked_at ]
      )
    end

    if upsert_rows.any?
      upsert_all(
        upsert_rows,
        unique_by: %i[sync_source_id row_id field_id],
        update_only: %i[last_known_value value_last_updated_at last_checked_at checked_count]
      )
    end

    results
  end

  # Admin/cron helper to purge stale entries
  # @param older_than [Time] Delete baselines not checked since this time
  # @return [Integer] Number of records deleted
  def self.prune_stale(older_than:)
    stale_before(older_than).in_batches.delete_all
  end

  # Keep this lightweight and consistent for hashing/compare
  def self.canonicalize_value(obj)
    case obj
    when Hash
      obj.keys.sort.each_with_object({}) { |k, h| h[k.to_s] = canonicalize_value(obj[k]) }
    when Array
      obj.map { |v| canonicalize_value(v) }
    else
      obj
    end
  end

  private

  # Compare new value against baseline (uses canonicalize for JSONB comparison)
  def value_changed?(new_value)
    # Compare canonicalized JSON representations (handles nil properly)
    canonicalize(new_value).to_json != canonicalize(last_known_value).to_json
  end

  def canonicalize(obj)
    self.class.canonicalize_value(obj)
  end
end
