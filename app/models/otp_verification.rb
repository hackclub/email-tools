class OtpVerification < ApplicationRecord
  validates :email_normalized, :expires_at, :code_hash, :salt, presence: true

  scope :active, -> { where("expires_at > ?", Time.current).where(verified_at: nil) }
  scope :expired, -> { where("expires_at <= ?", Time.current) }
  scope :for_email, ->(email) { where(email_normalized: EmailNormalizer.normalize(email)) }

  def expired?
    expires_at <= Time.current
  end

  def verified?
    verified_at.present?
  end

  def increment_attempts!
    increment!(:attempts)
  end

  def mark_verified!
    update!(verified_at: Time.current)
  end
end
