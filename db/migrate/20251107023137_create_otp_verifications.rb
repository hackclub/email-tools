class CreateOtpVerifications < ActiveRecord::Migration[8.0]
  def change
    create_table :otp_verifications do |t|
      t.string :email_normalized, null: false
      t.string :code_hash, null: false
      t.datetime :expires_at, null: false
      t.datetime :verified_at
      t.integer :attempts, default: 0, null: false

      t.timestamps
    end

    add_index :otp_verifications, [ :email_normalized, :expires_at ]
    add_index :otp_verifications, :expires_at
  end
end
