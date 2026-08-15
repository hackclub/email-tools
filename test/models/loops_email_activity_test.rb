require "test_helper"

class LoopsEmailActivityTest < ActiveSupport::TestCase
  def setup
    LoopsContactChangeAudit.destroy_all
    LoopsEmailActivity.destroy_all
  end

  def teardown
    LoopsContactChangeAudit.destroy_all
    LoopsEmailActivity.destroy_all
  end

  def create_audit!(email:, occurred_at:)
    LoopsContactChangeAudit.create!(
      email_normalized: email,
      field_name: "firstName",
      occurred_at: occurred_at,
      is_self_service: true
    )
  end

  test "creating an audit creates a summary row with its occurred_at" do
    time = Time.parse("2026-08-01T10:00:00Z")
    create_audit!(email: "a@example.com", occurred_at: time)

    activity = LoopsEmailActivity.find_by(email_normalized: "a@example.com")
    assert_not_nil activity, "Summary row should be created when an audit is created"
    assert_equal time, activity.last_occurred_at
  end

  test "a later audit advances last_occurred_at" do
    create_audit!(email: "a@example.com", occurred_at: Time.parse("2026-08-01T10:00:00Z"))
    later = Time.parse("2026-08-02T10:00:00Z")
    create_audit!(email: "a@example.com", occurred_at: later)

    assert_equal later, LoopsEmailActivity.find_by(email_normalized: "a@example.com").last_occurred_at
    assert_equal 1, LoopsEmailActivity.where(email_normalized: "a@example.com").count
  end

  test "an out-of-order older audit does not regress last_occurred_at" do
    newest = Time.parse("2026-08-02T10:00:00Z")
    create_audit!(email: "a@example.com", occurred_at: newest)
    create_audit!(email: "a@example.com", occurred_at: Time.parse("2026-07-01T10:00:00Z"))

    assert_equal newest, LoopsEmailActivity.find_by(email_normalized: "a@example.com").last_occurred_at
  end

  test "distinct emails get distinct summary rows" do
    create_audit!(email: "a@example.com", occurred_at: Time.current)
    create_audit!(email: "b@example.com", occurred_at: Time.current)

    assert_equal 2, LoopsEmailActivity.count
  end

  test "record! upserts directly" do
    time = Time.parse("2026-08-01T10:00:00Z")
    LoopsEmailActivity.record!(email_normalized: "c@example.com", occurred_at: time)
    assert_equal time, LoopsEmailActivity.find_by(email_normalized: "c@example.com").last_occurred_at

    # Advancing
    later = time + 1.day
    LoopsEmailActivity.record!(email_normalized: "c@example.com", occurred_at: later)
    assert_equal later, LoopsEmailActivity.find_by(email_normalized: "c@example.com").last_occurred_at

    # Not regressing
    LoopsEmailActivity.record!(email_normalized: "c@example.com", occurred_at: time)
    assert_equal later, LoopsEmailActivity.find_by(email_normalized: "c@example.com").last_occurred_at
  end
end
