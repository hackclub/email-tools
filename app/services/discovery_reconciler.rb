class DiscoveryReconciler
  def initialize(adapters:)
    @adapters = adapters # [{source: "airtable", adapter: Discovery::AirtableAdapter.new}]
  end

  def call
    @adapters.each do |a|
      begin
        reconcile_source(a[:source], a[:adapter])
      rescue => e
        Rails.logger.error("DiscoveryReconciler failed for #{a[:source]}: #{e.class} - #{e.message}")
        Rails.logger.error(e.backtrace.join("\n"))
        # Continue with other adapters even if one fails
      end
    end
  end

  private

  def reconcile_source(source_key, adapter)
    now = Time.current

    # 1) Fetch remote ids+names once (adapter tuned to be cheap)
    remote = adapter.list_ids_with_names # => [{id:, name:}...]

    # 2) Remove ignored using centralized IgnoreMatcher service
    matcher = IgnoreMatcher.for(source: source_key)

    desired = remote.reject do |r|
      # Check if any ignore pattern matches this source_id (O(1) for exact, O(R) for regex)
      matcher.match?(r[:id])
    end

    # 3) CREATE/UPDATE/REVIVE
    desired_ids = desired.map { |r| r[:id] }.to_set
    created_count = 0
    updated_count = 0
    revived_count = 0

    # Pre-fetch all local sources to prevent N+1 queries
    local_sources_by_source_id = SyncSource.with_deleted.where(source: source_key).index_by(&:source_id)
    new_sources_attrs = []

    desired.each do |r|
      existing = local_sources_by_source_id[r[:id]]

      # 1) Try to revive soft-deleted if present
      if existing && existing.deleted_at.present? && existing.deleted_at <= now
        existing.update_columns(
          deleted_at: nil,
          deleted_reason: nil,
          display_name: r[:name],
          display_name_updated_at: now,
          last_seen_at: now,
          seen_count: (existing.seen_count || 0) + 1,
          updated_at: now
        )
        revived_count += 1
        next
      end

      # 2) Update active if present (default_scope)
      if existing
        changes = {}
        if existing.display_name != r[:name]
          changes[:display_name] = r[:name]
          changes[:display_name_updated_at] = now
        end
        changes[:last_seen_at] = now
        changes[:seen_count] = (existing.seen_count || 0) + 1
        changes[:first_seen_at] = now if existing.first_seen_at.nil?

        unless changes.empty?
          existing.update_columns(changes.merge(updated_at: now))
          updated_count += 1
        end
        next
      end

      # 3) Create new (bulk insert)
      new_sources_attrs << {
        source: source_key,
        source_id: r[:id],
        poll_interval_seconds: 30,
        poll_jitter: 0.10,
        display_name: r[:name],
        display_name_updated_at: now,
        first_seen_at: now,
        last_seen_at: now,
        seen_count: 1,
        metadata: {},
        created_at: now,
        updated_at: now
      }
    end

    created_count = 0
    if new_sources_attrs.any?
      SyncSource.insert_all(new_sources_attrs)
      created_count = new_sources_attrs.length
    end

    # 4) RETIRE missing
    deleted_count = 0
    SyncSource.where(source: source_key).find_each do |row|
      next if desired_ids.include?(row.source_id)

      # Set last_seen_at if nil (for analytics)
      if row.last_seen_at.nil?
        row.update_columns(last_seen_at: now, updated_at: now)
      end

      # Immediately soft delete missing sources
      row.soft_delete!(reason: :disappeared)
      deleted_count += 1
    end

    # Also update deleted_reason for already-deleted sources that are still missing
    SyncSource.with_deleted.where(source: source_key)
              .where.not(deleted_at: nil)
              .where.not(source_id: desired_ids.to_a)
              .find_each do |row|
      # Set deleted_reason to :disappeared only if it's nil (preserve manual deletions)
      if row.deleted_reason.nil?
        row.update_columns(deleted_reason: :disappeared, updated_at: now)
      end
    end

    Rails.logger.info("DiscoveryReconciler[#{source_key}]: created=#{created_count}, updated=#{updated_count}, revived=#{revived_count}, deleted=#{deleted_count}")
  end
end
