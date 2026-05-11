require "test_helper"
require "minitest/mock"

class LoopsFieldBaselineMailingListTest < ActiveSupport::TestCase
  def setup
    LoopsFieldBaseline.destroy_all
    LoopsListSubscription.destroy_all
    @email = "test@example.com"
  end

  def teardown
    LoopsFieldBaseline.destroy_all
    LoopsListSubscription.destroy_all
  end

  test "seeds list subscriptions from contact response with mailingLists hash" do
    contact_hash = {
      "id" => "contact123",
      "email" => @email,
      "firstName" => "John",
      "mailingLists" => {
        "list1" => true,
        "list2" => true,
        "list3" => false
      }
    }

    count = LoopsFieldBaseline.seed_list_subscriptions_from_loops_response!(@email, contact_hash)

    assert_equal 2, count
    assert_equal 2, LoopsListSubscription.where(email_normalized: @email).count
    assert LoopsListSubscription.exists?(email_normalized: @email, list_id: "list1")
    assert LoopsListSubscription.exists?(email_normalized: @email, list_id: "list2")
    assert_not LoopsListSubscription.exists?(email_normalized: @email, list_id: "list3")
  end

  test "handles empty mailingLists hash" do
    contact_hash = {
      "id" => "contact123",
      "email" => @email,
      "mailingLists" => {}
    }

    count = LoopsFieldBaseline.seed_list_subscriptions_from_loops_response!(@email, contact_hash)

    assert_equal 0, count
    assert_equal 0, LoopsListSubscription.where(email_normalized: @email).count
  end

  test "handles missing mailingLists key" do
    contact_hash = {
      "id" => "contact123",
      "email" => @email
    }

    count = LoopsFieldBaseline.seed_list_subscriptions_from_loops_response!(@email, contact_hash)

    assert_equal 0, count
  end

  test "does not create duplicate subscriptions" do
    contact_hash = {
      "id" => "contact123",
      "email" => @email,
      "mailingLists" => {
        "list1" => true
      }
    }

    # First call
    count1 = LoopsFieldBaseline.seed_list_subscriptions_from_loops_response!(@email, contact_hash)
    assert_equal 1, count1

    # Second call with same data
    count2 = LoopsFieldBaseline.seed_list_subscriptions_from_loops_response!(@email, contact_hash)
    assert_equal 0, count2

    assert_equal 1, LoopsListSubscription.where(email_normalized: @email).count
  end

  test "check_contact_existence_and_load_baselines seeds subscriptions" do
    contact_hash = {
      "id" => "contact123",
      "email" => @email,
      "firstName" => "John",
      "mailingLists" => {
        "list1" => true
      }
    }

    LoopsService.stub :find_contact, [ contact_hash ] do
      result = LoopsFieldBaseline.check_contact_existence_and_load_baselines(email_normalized: @email)
      assert_equal true, result
    end

    assert_equal 1, LoopsListSubscription.where(email_normalized: @email).count
  end

  test "initial_payload_for_new_contact includes default list if configured" do
    ENV["DEFAULT_LOOPS_LIST_ID"] = "default_list_123"

    sync_source = SyncSource.create!(
      source: "airtable",
      source_id: "app123",
      poll_interval_seconds: 30
    )

    payload = LoopsFieldBaseline.initial_payload_for_new_contact(sync_source)

    assert payload.key?("mailingLists")
    assert_equal({ "default_list_123" => true }, payload["mailingLists"][:value])
    assert_equal :override, payload["mailingLists"][:strategy]

    ENV.delete("DEFAULT_LOOPS_LIST_ID")
  end

  test "initial_payload_for_new_contact excludes default list if not configured" do
    ENV.delete("DEFAULT_LOOPS_LIST_ID")

    sync_source = SyncSource.create!(
      source: "airtable",
      source_id: "app123",
      poll_interval_seconds: 30
    )

    payload = LoopsFieldBaseline.initial_payload_for_new_contact(sync_source)

    assert_not payload.key?("mailingLists")
  end

  test "SYSTEM_FIELDS includes mailingLists" do
    assert_includes LoopsFieldBaseline::SYSTEM_FIELDS, "mailingLists"
  end
end
