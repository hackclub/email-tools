class SoftDeleteAndSeenCols < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def up
    add_column :sync_sources, :deleted_at, :datetime
    add_column :sync_sources, :deleted_reason, :string
    add_column :sync_sources, :first_seen_at, :datetime
    add_column :sync_sources, :seen_count, :integer, null: false, default: 0
    add_column :sync_sources, :last_seen_at, :datetime

    # Remove existing unique index
    execute 'DROP INDEX CONCURRENTLY IF EXISTS index_sync_sources_on_source_and_source_id'

    # Create partial unique index (only for active rows)
    execute "CREATE UNIQUE INDEX CONCURRENTLY index_sync_sources_active_unique ON sync_sources (source, source_id) WHERE deleted_at IS NULL"
  end

  def down
    execute "DROP INDEX CONCURRENTLY IF EXISTS index_sync_sources_active_unique;"

    add_index :sync_sources, [ :source, :source_id ], unique: true, name: "index_sync_sources_on_source_and_source_id", algorithm: :concurrently

    remove_column :sync_sources, :last_seen_at
    remove_column :sync_sources, :seen_count
    remove_column :sync_sources, :first_seen_at
    remove_column :sync_sources, :deleted_reason
    remove_column :sync_sources, :deleted_at
  end
end
