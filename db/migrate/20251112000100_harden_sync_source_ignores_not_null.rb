class HardenSyncSourceIgnoresNotNull < ActiveRecord::Migration[8.0]
  def up
    execute "DELETE FROM sync_source_ignores WHERE source IS NULL OR source_id IS NULL"
    change_column_null :sync_source_ignores, :source, false
    change_column_null :sync_source_ignores, :source_id, false
  end

  def down
    change_column_null :sync_source_ignores, :source, true
    change_column_null :sync_source_ignores, :source_id, true
  end
end
