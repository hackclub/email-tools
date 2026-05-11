module ValueNormalizer
  module_function

  # Normalize values coming *from Airtable*
  # @param value [Object] The value to normalize
  # @return [Object] Normalized value
  def from_airtable(value)
    v = value

    # 1) Unwrap one-element arrays (Airtable lookups/rollups often return ["x"])
    if v.is_a?(Array)
      v = v.compact
      return nil if v.empty?
      return from_airtable(v.first) if v.size == 1
      return v # multi-value arrays stay arrays
    end

    # 2) Trim strings; empty -> nil
    if v.is_a?(String)
      s = v.strip
      return nil if s.empty?
      return s
    end

    v
  end
end
