require "digest"

module AiProcessors
  class ExtractFullAddress
    def self.call(raw_input:, country_hint: nil)
      return {} if raw_input.blank?

      # Normalize input
      normalized_input = raw_input.to_s.strip

      # Get prompt
      prompt = Ai::Prompts::ExtractFullAddress.call(raw_input: normalized_input, country_hint: country_hint)

      # Build cache key: hash of prompt + schema properties + temp
      # This automatically invalidates when prompt or schema changes
      schema_props = Ai::Prompts::ExtractFullAddress::Schema.properties.to_json
      temp = 0
      cache_key = Digest::SHA256.hexdigest(prompt + schema_props + temp.to_s)

      # Generate or get from cache
      extracted_data = Ai::Client.get_or_generate(
        cache_key: cache_key,
        prompt: prompt,
        schema_class: Ai::Prompts::ExtractFullAddress::Schema
      )

      # Filter to only fields we want
      extracted_data.select { |k, _|
        [ "addressLine1", "addressLine2", "addressCity", "addressState", "addressZipCode", "addressCountry" ].include?(k)
      }
    end
  end
end
