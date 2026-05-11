class CreateLoopsListTables < ActiveRecord::Migration[8.0]
  def change
    create_table :loops_lists do |t|
      t.string   :loops_list_id, null: false
      t.string   :name
      t.boolean  :is_public
      t.text     :description
      t.datetime :synced_at
      t.timestamps
    end
    add_index :loops_lists, :loops_list_id, unique: true

    create_table :loops_list_subscriptions do |t|
      t.string     :email_normalized, null: false
      t.string     :list_id,          null: false
      t.datetime   :subscribed_at,    null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamps
    end
    add_index :loops_list_subscriptions, [ :email_normalized, :list_id ],
              unique: true, name: "idx_unique_loops_list_subscriptions"
    add_index :loops_list_subscriptions, :email_normalized
  end
end
