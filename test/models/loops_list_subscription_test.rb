require "test_helper"

class LoopsListSubscriptionTest < ActiveSupport::TestCase
  def setup
    LoopsListSubscription.destroy_all
    @sync_source = SyncSource.create!(
      source: "airtable",
      source_id: "app123",
      poll_interval_seconds: 30
    )
    @email = "test@example.com"
    @list_id = "list123"
  end

  def teardown
    LoopsListSubscription.destroy_all
    SyncSource.destroy_all
  end

  test "validates email_normalized presence" do
    subscription = LoopsListSubscription.new(list_id: @list_id, subscribed_at: Time.current)
    assert_not subscription.valid?
    assert_includes subscription.errors[:email_normalized], "can't be blank"
  end

  test "validates list_id presence" do
    subscription = LoopsListSubscription.new(email_normalized: @email, subscribed_at: Time.current)
    assert_not subscription.valid?
    assert_includes subscription.errors[:list_id], "can't be blank"
  end

  test "subscribed_at is automatically set by database default" do
    # subscribed_at is automatically set by database default (CURRENT_TIMESTAMP)
    # No validation needed since DB ensures it's always set
    subscription = LoopsListSubscription.new(email_normalized: @email, list_id: @list_id)
    assert subscription.valid?, "Subscription should be valid - subscribed_at is set by DB"
    subscription.save!
    assert_not_nil subscription.subscribed_at, "subscribed_at should be automatically set by database"
  end

  test "validates uniqueness of email_normalized and list_id" do
    LoopsListSubscription.create!(
      email_normalized: @email,
      list_id: @list_id,
      subscribed_at: Time.current
    )

    duplicate = LoopsListSubscription.new(
      email_normalized: @email,
      list_id: @list_id,
      subscribed_at: Time.current
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email_normalized], "has already been taken"
  end

  test "can create valid subscription" do
    subscription = LoopsListSubscription.create!(
      email_normalized: @email,
      list_id: @list_id,
      subscribed_at: Time.current
    )

    assert_not_nil subscription.id
    assert_equal @email, subscription.email_normalized
    assert_equal @list_id, subscription.list_id
  end

  test "allows same email with different list_id" do
    LoopsListSubscription.create!(
      email_normalized: @email,
      list_id: @list_id,
      subscribed_at: Time.current
    )

    different_list = LoopsListSubscription.create!(
      email_normalized: @email,
      list_id: "list456",
      subscribed_at: Time.current
    )

    assert_not_nil different_list.id
    assert_equal 2, LoopsListSubscription.where(email_normalized: @email).count
  end
end
