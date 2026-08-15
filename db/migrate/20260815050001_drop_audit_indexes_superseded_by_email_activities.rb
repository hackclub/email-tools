class DropAuditIndexesSupersededByEmailActivities < ActiveRecord::Migration[8.1]
  # DROP/CREATE INDEX CONCURRENTLY cannot run inside a transaction
  disable_ddl_transaction!

  # With the admin email list and search now reading loops_email_activities,
  # nothing queries loops_contact_change_audits by email pattern or by bare
  # email equality anymore:
  #   - the trigram index (276 MB) served only the admin search
  #   - the single-column email_normalized btree (62 MB) served only the
  #     old COUNT(DISTINCT email_normalized); the audit-log show page uses
  #     the (email_normalized, occurred_at) composite, which stays.
  def up
    remove_index :loops_contact_change_audits,
                 name: "idx_loops_contact_change_audits_email_trgm",
                 algorithm: :concurrently, if_exists: true
    remove_index :loops_contact_change_audits,
                 name: "index_loops_contact_change_audits_on_email_normalized",
                 algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :loops_contact_change_audits, :email_normalized,
              using: :gin,
              opclass: :gin_trgm_ops,
              name: "idx_loops_contact_change_audits_email_trgm",
              algorithm: :concurrently, if_not_exists: true
    add_index :loops_contact_change_audits, :email_normalized,
              name: "index_loops_contact_change_audits_on_email_normalized",
              algorithm: :concurrently, if_not_exists: true
  end
end
