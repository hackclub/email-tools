require "timeout"

class SyncSourceIgnore < ApplicationRecord
  MAX_PATTERN_LENGTH = 200
  REGEX_TIMEOUT_SECONDS = 0.01 # 10ms timeout for regex evaluation

  validates :source, :source_id, presence: true

  # source_id is always treated as a regex pattern
  # For exact matches, use: ^exact_id$
  # For patterns, use: ^app.* or .*test.* etc.

  # Enforce uniqueness: same source + same pattern string can't be duplicated
  validates :source_id, uniqueness: { scope: :source }

  # Validate source_id is a valid regex and within length limits
  validate :source_id_is_valid_regex

  # Check if a source_id matches this ignore rule (source_id is always regex)
  # Protected against regex DoS with length limit and timeout
  def matches?(source_id_to_check)
    return false unless source_id.present?
    return false if source_id.length > MAX_PATTERN_LENGTH

    Timeout.timeout(REGEX_TIMEOUT_SECONDS) do
      compiled_regex.match?(source_id_to_check.to_s)
    end
  rescue RegexpError => e
    Rails.logger.error("Invalid regex pattern in SyncSourceIgnore##{id}: #{source_id} - #{e.message}")
    false
  rescue Timeout::Error
    Rails.logger.warn("SyncSourceIgnore##{id} regex timed out (possible DoS): #{source_id}")
    false
  end

  private

  def compiled_regex
    @compiled_regex ||= Regexp.new(source_id)
  end

  def source_id_is_valid_regex
    return unless source_id.present?

    if source_id.length > MAX_PATTERN_LENGTH
      errors.add(:source_id, "is too long (max #{MAX_PATTERN_LENGTH} characters)")
      return
    end

    Regexp.new(source_id)
  rescue RegexpError => e
    errors.add(:source_id, "is not a valid regex: #{e.message}")
  end
end
