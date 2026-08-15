# One row per email with its most recent audit activity. Maintained on every
# LoopsContactChangeAudit insert and read by the admin email list so that
# page doesn't have to aggregate millions of audit rows per request.
class LoopsEmailActivity < ApplicationRecord
  validates :email_normalized, presence: true, uniqueness: true
  validates :last_occurred_at, presence: true

  # Upsert: advances last_occurred_at, never regresses it (audits can be
  # recorded out of order).
  def self.record!(email_normalized:, occurred_at:)
    now = Time.current
    upsert_all(
      [ { email_normalized: email_normalized, last_occurred_at: occurred_at, created_at: now, updated_at: now } ],
      unique_by: :email_normalized,
      on_duplicate: Arel.sql(
        "last_occurred_at = GREATEST(loops_email_activities.last_occurred_at, EXCLUDED.last_occurred_at), " \
        "updated_at = EXCLUDED.updated_at"
      )
    )
  end
end
