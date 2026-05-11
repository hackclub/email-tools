require "test_helper"
require "minitest/mock"

module Ai
  class ContactMergerServiceTest < ActiveSupport::TestCase
    def setup
      @main_email = "zach@hackclub.com"
      @contacts = [
        {
          "email" => "zach@hackclub.com",
          "firstName" => "Zach",
          "lastName" => "Latta",
          "createdAt" => "2020-01-01T00:00:00Z"
        },
        {
          "email" => "zach+test@hackclub.com",
          "firstName" => "Zach",
          "lastName" => "Latta",
          "createdAt" => "2021-01-01T00:00:00Z",
          "tags" => [ "test-tag" ]
        }
      ]
    end

    test "successfully merges contacts when all AI results match" do
      merged_result = {
        "email" => "zach@hackclub.com",
        "firstName" => "Zach",
        "lastName" => "Latta",
        "createdAt" => "2020-01-01T00:00:00Z", # Oldest date
        "tags" => [ "test-tag" ]
      }

      # Mock 3 identical AI calls
      original_method = Ai::Client.method(:structured_generate)
      Ai::Client.define_singleton_method(:structured_generate) { |**args| merged_result }
      begin
        result = ContactMergerService.call(contacts: @contacts, main_email: @main_email)
        assert_equal merged_result, result
      ensure
        Ai::Client.define_singleton_method(:structured_generate, original_method)
      end
    end

    test "retries when AI results don't match" do
      merged_result = { "firstName" => "Zach", "lastName" => "Latta" }

      call_count = 0
      original_method = Ai::Client.method(:structured_generate)
      Ai::Client.define_singleton_method(:structured_generate) do |**args|
        call_count += 1
        if call_count <= 3
          # First attempt: results don't match (each call returns different value)
          { "firstName" => "Different#{call_count}" }
        elsif call_count <= 6
          # Second attempt: all 3 calls return same value (they match)
          merged_result
        else
          merged_result
        end
      end
      begin
        result = ContactMergerService.call(contacts: @contacts, main_email: @main_email)
        assert_equal merged_result, result
        assert call_count >= 6, "Should have retried (at least 6 calls = 2 attempts * 3 parallel)"
      ensure
        Ai::Client.define_singleton_method(:structured_generate, original_method)
      end
    end

    test "raises error after max retries if results still don't match" do
      call_count = 0
      original_method = Ai::Client.method(:structured_generate)
      Ai::Client.define_singleton_method(:structured_generate) do |**args|
        call_count += 1
        # Always return different results
        { "attempt" => call_count }
      end
      begin
        assert_raises(RuntimeError) do
          ContactMergerService.call(contacts: @contacts, main_email: @main_email)
        end
        # Should have tried 3 times (initial + 2 retries) * 3 parallel calls = 9 calls
        assert call_count >= 9
      ensure
        Ai::Client.define_singleton_method(:structured_generate, original_method)
      end
    end

    test "handles date fields correctly (chooses oldest)" do
      contacts_with_dates = [
        {
          "email" => "zach@hackclub.com",
          "createdAt" => "2021-01-01T00:00:00Z"
        },
        {
          "email" => "zach+test@hackclub.com",
          "createdAt" => "2020-01-01T00:00:00Z" # Older
        }
      ]

      merged_result = {
        "email" => "zach@hackclub.com",
        "createdAt" => "2020-01-01T00:00:00Z" # Should choose oldest
      }

      original_method = Ai::Client.method(:structured_generate)
      Ai::Client.define_singleton_method(:structured_generate) { |**args| merged_result }
      begin
        result = ContactMergerService.call(contacts: contacts_with_dates, main_email: @main_email)
        assert_equal "2020-01-01T00:00:00Z", result["createdAt"]
      ensure
        Ai::Client.define_singleton_method(:structured_generate, original_method)
      end
    end

    test "prioritizes main_email data for non-date fields" do
      contacts_with_conflicts = [
        {
          "email" => "zach@hackclub.com",
          "firstName" => "Zachary" # Main email value
        },
        {
          "email" => "zach+test@hackclub.com",
          "firstName" => "Zach" # Alt email value
        }
      ]

      merged_result = {
        "email" => "zach@hackclub.com",
        "firstName" => "Zachary" # Should prefer main email
      }

      original_method = Ai::Client.method(:structured_generate)
      Ai::Client.define_singleton_method(:structured_generate) { |**args| merged_result }
      begin
        result = ContactMergerService.call(contacts: contacts_with_conflicts, main_email: @main_email)
        assert_equal "Zachary", result["firstName"]
      ensure
        Ai::Client.define_singleton_method(:structured_generate, original_method)
      end
    end

    test "handles empty contacts array" do
      merged_result = {}
      original_method = Ai::Client.method(:structured_generate)
      Ai::Client.define_singleton_method(:structured_generate) { |**args| merged_result }
      begin
        result = ContactMergerService.call(contacts: [], main_email: @main_email)
        assert_equal merged_result, result
      ensure
        Ai::Client.define_singleton_method(:structured_generate, original_method)
      end
    end
  end
end
