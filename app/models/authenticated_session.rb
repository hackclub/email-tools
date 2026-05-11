require "securerandom"

class AuthenticatedSession < ApplicationRecord
  validates :email_normalized, :token, :expires_at, presence: true
  validates :token, uniqueness: true

  scope :active, -> { where("expires_at > ?", Time.current) }
  scope :expired, -> { where("expires_at <= ?", Time.current) }
  scope :for_email, ->(email) { where(email_normalized: EmailNormalizer.normalize(email)) }

  before_validation :generate_token, on: :create
  before_validation :set_expires_at, on: :create

  def expired?
    expires_at <= Time.current
  end

  def valid_token?(provided_token)
    ActiveSupport::SecurityUtils.secure_compare(token, provided_token) && !expired?
  end

  private

  def generate_token
    self.token ||= SecureRandom.hex(32)
  end

  def set_expires_at
    self.expires_at ||= 1.hour.from_now
  end
end
