class TuneLoopsContactChangeAuditIndexes < ActiveRecord::Migration[8.0]
  # CREATE/DROP INDEX CONCURRENTLY cannot run inside a transaction
  disable_ddl_transaction!

  # Measured in production on 2026-08-14 (5.45M rows, 12 GB table, stats never
  # reset since the database was created):
  #
  # 1. The admin email search (email_normalized ILIKE '%q%') cannot use any
  #    btree index and walks all ~5.4M index entries (~1.4s per search).
  #    A trigram GIN index turns selective searches into millisecond bitmap
  #    scans.
  #
  # 2. Four indexes had zero scans in production and no query paths in the
  #    app code (the only reads of this table are the two admin pages, which
  #    use the (email_normalized, occurred_at) composite and the
  #    email_normalized btree):
  #      - provenance GIN        714 MB
  #      - occurred_at           114 MB
  #      - is_self_service        51 MB
  #      - sync_source_id         50 MB
  #    Together ~930 MB of dead weight that every audit insert must maintain.
  def up
    enable_extension "pg_trgm" unless extension_enabled?("pg_trgm")

    add_index :loops_contact_change_audits, :email_normalized,
              using: :gin,
              opclass: :gin_trgm_ops,
              name: "idx_loops_contact_change_audits_email_trgm",
              algorithm: :concurrently,
              if_not_exists: true

    remove_index :loops_contact_change_audits,
                 name: "index_loops_contact_change_audits_on_provenance",
                 algorithm: :concurrently, if_exists: true
    remove_index :loops_contact_change_audits,
                 name: "index_loops_contact_change_audits_on_occurred_at",
                 algorithm: :concurrently, if_exists: true
    remove_index :loops_contact_change_audits,
                 name: "index_loops_contact_change_audits_on_is_self_service",
                 algorithm: :concurrently, if_exists: true
    remove_index :loops_contact_change_audits,
                 name: "index_loops_contact_change_audits_on_sync_source_id",
                 algorithm: :concurrently, if_exists: true
  end

  def down
    remove_index :loops_contact_change_audits,
                 name: "idx_loops_contact_change_audits_email_trgm",
                 algorithm: :concurrently, if_exists: true

    add_index :loops_contact_change_audits, :provenance,
              using: :gin,
              name: "index_loops_contact_change_audits_on_provenance",
              algorithm: :concurrently, if_not_exists: true
    add_index :loops_contact_change_audits, :occurred_at,
              name: "index_loops_contact_change_audits_on_occurred_at",
              algorithm: :concurrently, if_not_exists: true
    add_index :loops_contact_change_audits, :is_self_service,
              name: "index_loops_contact_change_audits_on_is_self_service",
              algorithm: :concurrently, if_not_exists: true
    add_index :loops_contact_change_audits, :sync_source_id,
              name: "index_loops_contact_change_audits_on_sync_source_id",
              algorithm: :concurrently, if_not_exists: true
  end
end
