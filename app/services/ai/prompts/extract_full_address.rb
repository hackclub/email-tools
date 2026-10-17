require "schematist"

module Ai
  module Prompts
    class ExtractFullAddress
      def self.call(raw_input:, country_hint: nil)
        <<~PROMPT
          A user provided us with unstructured data for their mailing address. We need to break it into addressLine1, addressLine2 (optional), addressCity, addressState, addressZipCode, and addressCountry parts

          1. Break the provided info into parts.

          2. Strip unnecessary punctuation

          3. Ensure that the parts, when combined, contain all of the user-provided text. Some countries have complicated address systems, and parts of address text that seem insignificant are crucial for mail to be delivered.

          4. Do not invent anything in your returned address (ex. if the user didn't specify a country, don't list a country, and so on)

          5. There is a maximum of 30 characters per part.

          User provided info:

          #{raw_input}
        PROMPT
      end

      # Schema definition - defines the structure of the response
      class Schema < Schematist::Schema
        string :addressLine1, description: "Street address line 1"
        string :addressLine2, description: "Street address line 2 (optional)", required: false
        string :addressCity, description: "City name"
        string :addressState, description: "State or province code"
        string :addressZipCode, description: "ZIP or postal code"
        string :addressCountry, description: "Country code or name"
      end
    end
  end
end
