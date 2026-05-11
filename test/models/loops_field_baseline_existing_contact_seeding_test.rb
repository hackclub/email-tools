require "test_helper"
require "minitest/mock"

class LoopsFieldBaselineExistingContactSeedingTest < ActiveSupport::TestCase
  def setup
    LoopsFieldBaseline.destroy_all
    LoopsListSubscription.destroy_all
    @email = "existing@example.com"
    @email_normalized = EmailNormalizer.normalize(@email)
  end

  def teardown
    LoopsFieldBaseline.destroy_all
    LoopsListSubscription.destroy_all
  end

  test "seeds mailing list subscriptions when loading baselines for new contact" do
    # Contact exists in Loops but we don't have baselines yet
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

    # Simulate checking contact existence and loading baselines
    LoopsService.stub :find_contact, [ contact_hash ] do
      result = LoopsFieldBaseline.check_contact_existence_and_load_baselines(email_normalized: @email_normalized)
      assert_equal true, result
    end

    # Should seed mailing list subscriptions
    subscriptions = LoopsListSubscription.where(email_normalized: @email_normalized)
    assert_equal 2, subscriptions.count, "Should seed 2 subscriptions (list1 and list2, not list3)"
    assert LoopsListSubscription.exists?(email_normalized: @email_normalized, list_id: "list1")
    assert LoopsListSubscription.exists?(email_normalized: @email_normalized, list_id: "list2")
    assert_not LoopsListSubscription.exists?(email_normalized: @email_normalized, list_id: "list3")
  end

  test "does not create duplicate subscriptions when seeding multiple times" do
    contact_hash = {
      "id" => "contact123",
      "email" => @email,
      "firstName" => "John",  # Add a writable field so baselines are created
      "mailingLists" => {
        "list1" => true
      }
    }

    # First call - creates baselines and subscriptions
    LoopsService.stub :find_contact, [ contact_hash ] do
      LoopsFieldBaseline.check_contact_existence_and_load_baselines(email_normalized: @email_normalized)
    end

    assert_equal 1, LoopsListSubscription.where(email_normalized: @email_normalized).count
    assert LoopsFieldBaseline.where(email_normalized: @email_normalized).exists?, "Baselines should exist after first call"

    # Second call - baselines exist, so no API call and no duplicate seeding
    # The method should return early without calling find_contact
    result = LoopsFieldBaseline.check_contact_existence_and_load_baselines(email_normalized: @email_normalized)
    assert_equal true, result

    # Should still have only one subscription (no duplicates)
    assert_equal 1, LoopsListSubscription.where(email_normalized: @email_normalized).count
  end

  test "handles new contact with no mailing lists" do
    contact_hash = {
      "id" => "contact123",
      "email" => @email,
      "firstName" => "John",
      "mailingLists" => {}
    }

    LoopsService.stub :find_contact, [ contact_hash ] do
      result = LoopsFieldBaseline.check_contact_existence_and_load_baselines(email_normalized: @email_normalized)
      assert_equal true, result
    end

    # Should not create any subscriptions
    assert_equal 0, LoopsListSubscription.where(email_normalized: @email_normalized).count
  end

  test "handles new contact with missing mailingLists key" do
    contact_hash = {
      "id" => "contact123",
      "email" => @email,
      "firstName" => "John"
      # No mailingLists key
    }

    LoopsService.stub :find_contact, [ contact_hash ] do
      result = LoopsFieldBaseline.check_contact_existence_and_load_baselines(email_normalized: @email_normalized)
      assert_equal true, result
    end

    # Should not create any subscriptions
    assert_equal 0, LoopsListSubscription.where(email_normalized: @email_normalized).count
  end

  test "does not fetch or seed when baselines already exist" do
    # Create baseline for existing contact
    baseline = LoopsFieldBaseline.create!(
      email_normalized: @email_normalized,
      field_name: "firstName",
      last_sent_value: "John",
      last_sent_at: 1.hour.ago,
      expires_at: 90.days.from_now
    )

    # Create an existing subscription
    existing_sub = LoopsListSubscription.create!(
      email_normalized: @email_normalized,
      list_id: "list1",
      subscribed_at: 2.hours.ago
    )

    initial_count = LoopsListSubscription.where(email_normalized: @email_normalized).count

    # Since baselines already exist, should skip API call and return early
    LoopsService.stub :find_contact, ->(*) { raise "Should not be called!" } do
      result = LoopsFieldBaseline.check_contact_existence_and_load_baselines(email_normalized: @email_normalized)
      assert_equal true, result
    end

    # Should still have only the original subscription (count unchanged)
    assert_equal initial_count, LoopsListSubscription.where(email_normalized: @email_normalized).count
    assert_equal 1, LoopsListSubscription.where(email_normalized: @email_normalized).count
    assert LoopsListSubscription.exists?(email_normalized: @email_normalized, list_id: "list1")

    # Original subscription should be preserved
    existing_sub.reload
    assert_equal 2.hours.ago.to_i, existing_sub.subscribed_at.to_i, "Subscription timestamp should be preserved (within 1 second tolerance)"
  end
end
