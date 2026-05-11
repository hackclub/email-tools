require "test_helper"
require "minitest/mock"

class DiscoveryReconcilerWorkerTest < ActiveSupport::TestCase
  def setup
    SyncSource.destroy_all
    SyncSourceIgnore.destroy_all
  end

  def teardown
    SyncSource.destroy_all
    SyncSourceIgnore.destroy_all
  end

  test "performs reconciliation with Airtable adapter when token present" do
    adapter_instance = Minitest::Mock.new
    adapter_instance.expect :list_ids_with_names, [
      { id: "base1", name: "Base One" }
    ]

    adapter_class = Minitest::Mock.new
    adapter_class.expect :new, adapter_instance

    # Stub ENV and adapter class
    original_env = ENV["AIRTABLE_PERSONAL_ACCESS_TOKEN"]
    ENV["AIRTABLE_PERSONAL_ACCESS_TOKEN"] = "token123"

    begin
      Discovery::AirtableAdapter.stub :new, adapter_instance do
        worker = DiscoveryReconcilerWorker.new
        worker.perform

        assert_equal 1, SyncSource.count
        assert_not_nil SyncSource.find_by(source: "airtable", source_id: "base1")
        adapter_instance.verify
      end
    ensure
      ENV["AIRTABLE_PERSONAL_ACCESS_TOKEN"] = original_env
    end
  end

  test "skips Airtable adapter when token not present" do
    original_env = ENV["AIRTABLE_PERSONAL_ACCESS_TOKEN"]
    ENV.delete("AIRTABLE_PERSONAL_ACCESS_TOKEN")

    begin
      worker = DiscoveryReconcilerWorker.new
      worker.perform

      # Should not create any sources
      assert_equal 0, SyncSource.count
    ensure
      ENV["AIRTABLE_PERSONAL_ACCESS_TOKEN"] = original_env if original_env
    end
  end
end
