class LoopsListSubscription < ApplicationRecord
  validates :email_normalized, :list_id, presence: true
  validates :email_normalized, uniqueness: { scope: :list_id }
end
