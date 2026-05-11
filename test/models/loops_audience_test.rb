require "test_helper"

class LoopsAudienceTest < ActiveSupport::TestCase
  test "readonly? returns true" do
    # Create a new instance (we can't actually save it, but we can instantiate)
    audience = LoopsAudience.new
    assert audience.readonly?, "LoopsAudience should be readonly"
  end

  test "create raises ActiveRecord::ReadOnlyRecord" do
    assert_raises(ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only") do
      LoopsAudience.create(email: "test@example.com")
    end
  end

  test "create! raises ActiveRecord::ReadOnlyRecord" do
    assert_raises(ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only") do
      LoopsAudience.create!(email: "test@example.com")
    end
  end

  test "save raises ActiveRecord::ReadOnlyRecord" do
    audience = LoopsAudience.new(email: "test@example.com")
    assert_raises(ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only") do
      audience.save
    end
  end

  test "save! raises ActiveRecord::ReadOnlyRecord" do
    audience = LoopsAudience.new(email: "test@example.com")
    assert_raises(ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only") do
      audience.save!
    end
  end

  test "update raises ActiveRecord::ReadOnlyRecord" do
    # We can't actually load a record, but we can test the method exists
    # Since we can't query the warehouse DB in tests, we'll test with a new instance
    audience = LoopsAudience.new
    assert_raises(ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only") do
      audience.update(email: "new@example.com")
    end
  end

  test "update! raises ActiveRecord::ReadOnlyRecord" do
    audience = LoopsAudience.new
    assert_raises(ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only") do
      audience.update!(email: "new@example.com")
    end
  end

  test "destroy raises ActiveRecord::ReadOnlyRecord" do
    audience = LoopsAudience.new
    assert_raises(ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only") do
      audience.destroy
    end
  end

  test "destroy! raises ActiveRecord::ReadOnlyRecord" do
    audience = LoopsAudience.new
    assert_raises(ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only") do
      audience.destroy!
    end
  end

  test "insert_all raises ActiveRecord::ReadOnlyRecord" do
    assert_raises(ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only") do
      LoopsAudience.insert_all([ { email: "test@example.com" } ])
    end
  end

  test "upsert_all raises ActiveRecord::ReadOnlyRecord" do
    assert_raises(ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only") do
      LoopsAudience.upsert_all([ { email: "test@example.com" } ])
    end
  end
end
