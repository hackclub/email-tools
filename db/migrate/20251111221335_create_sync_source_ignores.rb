class CreateSyncSourceIgnores < ActiveRecord::Migration[8.0]
  def change
    create_table :sync_source_ignores do |t|
      t.string :source,    null: false  # e.g., "airtable"
      t.string :source_id, null: false  # e.g., base id
      t.string :reason
      t.timestamps
    end
    add_index :sync_source_ignores, [ :source, :source_id ], unique: true
  end
end
