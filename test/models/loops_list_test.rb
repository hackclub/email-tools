require "test_helper"

class LoopsListTest < ActiveSupport::TestCase
  def setup
    LoopsList.destroy_all
  end

  def teardown
    LoopsList.destroy_all
  end

  test "validates loops_list_id presence" do
    list = LoopsList.new
    assert_not list.valid?
    assert_includes list.errors[:loops_list_id], "can't be blank"
  end

  test "validates loops_list_id uniqueness" do
    LoopsList.create!(loops_list_id: "list123", name: "Test List")

    duplicate = LoopsList.new(loops_list_id: "list123", name: "Another List")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:loops_list_id], "has already been taken"
  end

  test "can create valid list" do
    list = LoopsList.create!(
      loops_list_id: "list123",
      name: "Test List",
      description: "Test description",
      is_public: true
    )

    assert_not_nil list.id
    assert_equal "list123", list.loops_list_id
    assert_equal "Test List", list.name
  end
end
