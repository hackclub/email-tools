class LoopsContactChangeAudit < ApplicationRecord
  belongs_to :sync_source, optional: true

  validates :occurred_at, :email_normalized, :field_name, presence: true
  validates :sync_source_id, presence: true, unless: :is_self_service?
  validates :is_self_service, inclusion: { in: [ true, false ] }

  scope :for_email, ->(email) { where(email_normalized: email) }
  scope :for_sync_source, ->(source) { where(sync_source_id: source.id) }
  scope :since, ->(time) { where("occurred_at >= ?", time) }
  scope :self_service, -> { where(is_self_service: true) }
  scope :sync_source_changes, -> { where(is_self_service: false) }
end
