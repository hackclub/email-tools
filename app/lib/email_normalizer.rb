module EmailNormalizer
  # Normalize email address: lowercase and trim whitespace
  # @param email [String, nil] The email address to normalize
  # @return [String, nil] Normalized email or nil if blank/invalid
  def self.normalize(email)
    return nil if email.nil?
    email = email.first if email.is_a?(Array)
    return nil if email.nil?
    normalized = email.to_s.strip.downcase
    normalized.empty? ? nil : normalized
  end
end
