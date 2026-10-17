class LoopsOutboxEnvelope < ApplicationRecord
  belongs_to :sync_source, optional: true

  # PostgreSQL enum - no integer mapping needed, PostgreSQL handles it
  enum :status, {
    queued: "queued",
    sent: "sent",
    ignored_noop: "ignored_noop",
    failed: "failed",
    partially_sent: "partially_sent"
  }

  validates :email_normalized, :payload, :provenance, presence: true
  validates :status, presence: true

  scope :queued, -> { where(status: :queued) }
  scope :sent, -> { where(status: :sent) }
  scope :failed, -> { where(status: :failed) }
  scope :for_email, ->(email) { where(email_normalized: email) }

  SELF_SERVICE_SOURCE_TYPE = "self_service".freeze

  scope :self_service, -> { where("provenance->>'sync_source_type' = ?", SELF_SERVICE_SOURCE_TYPE) }

  # Queued by a person on a self-service page (e.g. /subscriptions) rather than
  # by a sync source. The dispatcher sends these as explicit user intent.
  def self_service?
    provenance.is_a?(Hash) && provenance["sync_source_type"] == SELF_SERVICE_SOURCE_TYPE
  end
end
