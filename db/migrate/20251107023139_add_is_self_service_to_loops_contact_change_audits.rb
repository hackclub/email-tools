class AddIsSelfServiceToLoopsContactChangeAudits < ActiveRecord::Migration[8.0]
  def change
    # Add is_self_service column
    add_column :loops_contact_change_audits, :is_self_service, :boolean, default: false, null: false

    # Make sync_source_id nullable and remove foreign key constraint
    remove_foreign_key :loops_contact_change_audits, :sync_sources
    change_column_null :loops_contact_change_audits, :sync_source_id, true

    # Add index on is_self_service for querying
    add_index :loops_contact_change_audits, :is_self_service
  end
end
