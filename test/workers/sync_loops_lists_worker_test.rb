require "test_helper"
require "minitest/mock"

class SyncLoopsListsWorkerTest < ActiveJob::TestCase
  def setup
    LoopsList.destroy_all
  end

  def teardown
    LoopsList.destroy_all
  end

  test "syncs lists from Loops API" do
    mock_lists = [
      {
        "id" => "list1",
        "name" => "Beta Users",
        "description" => "Beta testers",
        "isPublic" => true
      },
      {
        "id" => "list2",
        "name" => "Newsletter",
        "description" => nil,
        "isPublic" => false
      }
    ]

    LoopsService.stub :list_mailing_lists, mock_lists do
      SyncLoopsListsWorker.new.perform
    end

    assert_equal 2, LoopsList.count

    list1 = LoopsList.find_by(loops_list_id: "list1")
    assert_not_nil list1
    assert_equal "Beta Users", list1.name
    assert_equal "Beta testers", list1.description
    assert_equal true, list1.is_public
    assert_not_nil list1.synced_at

    list2 = LoopsList.find_by(loops_list_id: "list2")
    assert_not_nil list2
    assert_equal "Newsletter", list2.name
    assert_nil list2.description
    assert_equal false, list2.is_public
  end

  test "updates existing lists on sync" do
    existing = LoopsList.create!(
      loops_list_id: "list1",
      name: "Old Name",
      description: "Old description",
      is_public: false,
      synced_at: 1.hour.ago
    )

    mock_lists = [
      {
        "id" => "list1",
        "name" => "New Name",
        "description" => "New description",
        "isPublic" => true
      }
    ]

    LoopsService.stub :list_mailing_lists, mock_lists do
      SyncLoopsListsWorker.new.perform
    end

    assert_equal 1, LoopsList.count
    existing.reload
    assert_equal "New Name", existing.name
    assert_equal "New description", existing.description
    assert_equal true, existing.is_public
    assert existing.synced_at > 1.hour.ago
  end

  test "handles empty list response" do
    LoopsService.stub :list_mailing_lists, [] do
      SyncLoopsListsWorker.new.perform
    end

    assert_equal 0, LoopsList.count
  end

  test "deletes lists that are no longer in Loops API" do
    # Create lists that exist locally but not in API response
    old_list = LoopsList.create!(
      loops_list_id: "old_list",
      name: "Old List",
      synced_at: 1.hour.ago
    )

    # API returns only new_list, not old_list
    mock_lists = [
      {
        "id" => "new_list",
        "name" => "New List",
        "description" => nil,
        "isPublic" => true
      }
    ]

    LoopsService.stub :list_mailing_lists, mock_lists do
      SyncLoopsListsWorker.new.perform
    end

    # old_list should be deleted, new_list should exist
    assert_equal 1, LoopsList.count
    assert_nil LoopsList.find_by(loops_list_id: "old_list")
    assert_not_nil LoopsList.find_by(loops_list_id: "new_list")
  end

  test "handles API errors gracefully" do
    LoopsService.stub :list_mailing_lists, -> { raise StandardError.new("API Error") } do
      assert_raises(StandardError) do
        SyncLoopsListsWorker.new.perform
      end
    end

    assert_equal 0, LoopsList.count
  end
end
