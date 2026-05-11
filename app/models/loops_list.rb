class LoopsList < ApplicationRecord
  validates :loops_list_id, presence: true, uniqueness: true
end
