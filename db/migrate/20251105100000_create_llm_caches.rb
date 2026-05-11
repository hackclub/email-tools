class CreateLlmCaches < ActiveRecord::Migration[8.0]
  def change
    create_table :llm_caches do |t|
      t.string :task, null: false
      t.string :input_fingerprint, null: false
      t.jsonb :request_json, null: false
      t.jsonb :response_json, null: false
      t.integer :bytes_size, null: false
      t.datetime :last_used_at, null: false, default: -> { "CURRENT_TIMESTAMP" }

      t.timestamps
    end

    add_index :llm_caches, [ :task, :input_fingerprint ], unique: true
    add_index :llm_caches, :last_used_at
  end
end
