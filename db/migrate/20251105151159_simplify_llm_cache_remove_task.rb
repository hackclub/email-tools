class SimplifyLlmCacheRemoveTask < ActiveRecord::Migration[8.0]
  def up
    # Remove old composite index
    if index_exists?(:llm_caches, [ :task, :input_fingerprint ])
      remove_index :llm_caches, [ :task, :input_fingerprint ]
    end

    # Rename input_fingerprint to prompt_hash
    rename_column :llm_caches, :input_fingerprint, :prompt_hash

    # Remove task column
    remove_column :llm_caches, :task, :string

    # Add unique index on prompt_hash
    add_index :llm_caches, :prompt_hash, unique: true
  end

  def down
    # Remove prompt_hash index
    remove_index :llm_caches, :prompt_hash, if_exists: true

    # Add back task column
    add_column :llm_caches, :task, :string, null: false

    # Rename prompt_hash back to input_fingerprint
    rename_column :llm_caches, :prompt_hash, :input_fingerprint

    # Add back composite index
    add_index :llm_caches, [ :task, :input_fingerprint ], unique: true
  end
end
