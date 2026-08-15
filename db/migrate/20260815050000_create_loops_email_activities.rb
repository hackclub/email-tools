class CreateLoopsEmailActivities < ActiveRecord::Migration[8.1]
  # Summary table: one row per email with its most recent audit activity.
  # Maintained by an after_create callback on LoopsContactChangeAudit and
  # read by the admin email list, which previously aggregated all ~5.4M
  # audit rows (~1.5s per page load) on every request.
  def up
    create_table :loops_email_activities do |t|
      t.string :email_normalized, null: false
      t.datetime :last_occurred_at, null: false
      t.timestamps

      t.index :email_normalized, unique: true
      # Serves the paginated listing (ORDER BY last_occurred_at DESC, email ASC)
      t.index [ :last_occurred_at, :email_normalized ],
              order: { last_occurred_at: :desc, email_normalized: :asc },
              name: "idx_loops_email_activities_recency"
    end

    # Serves the admin search (email_normalized ILIKE '%q%')
    add_index :loops_email_activities, :email_normalized,
              using: :gin,
              opclass: :gin_trgm_ops,
              name: "idx_loops_email_activities_email_trgm"

    # Backfill from existing audits. Audits written by old-code processes
    # between this backfill and the new code going live can leave a summary
    # row slightly stale (or absent, for a brand-new email); the next audit
    # for that email self-heals it via the upsert callback.
    execute <<~SQL
      INSERT INTO loops_email_activities (email_normalized, last_occurred_at, created_at, updated_at)
      SELECT email_normalized, MAX(occurred_at), NOW(), NOW()
      FROM loops_contact_change_audits
      GROUP BY email_normalized
      ON CONFLICT (email_normalized) DO UPDATE
        SET last_occurred_at = GREATEST(loops_email_activities.last_occurred_at, EXCLUDED.last_occurred_at),
            updated_at = EXCLUDED.updated_at
    SQL
  end

  def down
    drop_table :loops_email_activities
  end
end
