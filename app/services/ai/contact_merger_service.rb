require "json"

module Ai
  class ContactMergerService
    MAX_RETRIES = 2

    # Merges contact data using parallel AI calls for consistency.
    # @param contacts [Array<Hash>] An array of contact data hashes from the Loops API.
    # @param main_email [String] The user's primary email address.
    # @return [Hash] The merged contact data hash.
    def self.call(contacts:, main_email:)
      retries = 0
      begin
        contacts_json = JSON.pretty_generate(contacts)
        prompt = Ai::Prompts::MergeContacts.call(contacts_json: contacts_json, main_email: main_email)

        # Run 3 AI calls in parallel
        threads = 3.times.map do
          Thread.new do
            Ai::Client.structured_generate(
              prompt: prompt,
              schema_class: Ai::Prompts::MergeContacts::Schema,
              model: "gpt-5",
              temp: 0,
              reasoning_effort: "high"
            )
          end
        end
        results = threads.map(&:value)

        # Deep sort keys for consistent comparison
        sorted_results = results.map { |res| deep_sort_hash(res) }

        # Verify that all results are identical
        if sorted_results.uniq.length == 1
          results.first # Return the original, unsorted version
        else
          Rails.logger.warn("AI::ContactMergerService: AI results are not consistent. Results: #{results.inspect}")
          raise "AI results are not consistent."
        end
      rescue => e
        retries += 1
        if retries <= MAX_RETRIES
          Rails.logger.warn("AI::ContactMergerService: Retrying due to error: #{e.message}")
          sleep(1) # Wait a moment before retrying
          retry
        else
          Rails.logger.error("AI::ContactMergerService: Failed after #{MAX_RETRIES} retries: #{e.message}")
          raise
        end
      end
    end

    private

    def self.deep_sort_hash(obj)
      case obj
      when Hash
        obj.keys.sort.each_with_object({}) do |key, seed|
          seed[key] = deep_sort_hash(obj[key])
        end
      when Array
        obj.map { |v| deep_sort_hash(v) }
      else
        obj
      end
    end
  end
end
