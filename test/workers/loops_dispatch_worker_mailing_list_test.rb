require "test_helper"
require "minitest/mock"

class LoopsDispatchWorkerMailingListTest < ActiveSupport::TestCase
  parallelize(workers: 1)
  self.use_transactional_tests = false

  def setup
    # Clean up first to ensure clean state
    cleanup_advisory_locks
    LoopsOutboxEnvelope.destroy_all
    LoopsFieldBaseline.destroy_all
    LoopsContactChangeAudit.destroy_all
    LoopsListSubscription.destroy_all
    LoopsList.destroy_all
    SyncSource.destroy_all

    @sync_source = SyncSource.create!(
      source: "airtable",
      source_id: "app123",
      poll_interval_seconds: 30
    )

    @email = "test@example.com"
    @email_normalized = EmailNormalizer.normalize(@email)

    # Store original LoopsService methods for restoration
    @original_update_contact = LoopsService.method(:update_contact) if LoopsService.respond_to?(:update_contact)
    @original_find_contact = LoopsService.method(:find_contact) if LoopsService.respond_to?(:find_contact)
  end

  def teardown
    cleanup_advisory_locks
    LoopsOutboxEnvelope.destroy_all
    LoopsFieldBaseline.destroy_all
    LoopsContactChangeAudit.destroy_all
    LoopsListSubscription.destroy_all
    LoopsList.destroy_all
    SyncSource.destroy_all

    # Restore original LoopsService methods
    if @original_update_contact
      LoopsService.define_singleton_method(:update_contact, @original_update_contact)
    end
    if @original_find_contact
      LoopsService.define_singleton_method(:find_contact, @original_find_contact)
    end
  end

  def build_test_provenance
    {
      "sync_source_id" => @sync_source.id,
      "sync_source_type" => "airtable",
      "sync_source_table_id" => "tbl123",
      "sync_source_record_id" => "rec123",
      "fields" => []
    }
  end

  def cleanup_advisory_locks
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock_all()")
  rescue => e
    Rails.logger.warn("Failed to cleanup advisory locks: #{e.message}")
  end

  test "filters out already-subscribed lists (idempotence)" do
    # Create existing subscription
    LoopsListSubscription.create!(
      email_normalized: @email_normalized,
      list_id: "list1",
      subscribed_at: 1.hour.ago
    )

    # Create list in catalog
    LoopsList.create!(loops_list_id: "list1", name: "List 1")
    LoopsList.create!(loops_list_id: "list2", name: "List 2")

    sent_payload = nil
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end

    envelope = LoopsOutboxEnvelope.create!(
      email_normalized: @email_normalized,
      payload: {
        "mailingLists" => {
          "value" => { "list1" => true, "list2" => true },
          "strategy" => "override",
          "modified_at" => Time.current.iso8601
        }
      },
      status: :queued,
      provenance: build_test_provenance,
      sync_source_id: @sync_source.id
    )

    worker = LoopsDispatchWorker.new
    worker.perform

    # Should only send list2 (list1 already subscribed)
    assert_equal "sent", envelope.reload.status
    assert_not_nil sent_payload
    assert_equal({ "list2" => true }, sent_payload["mailingLists"])
  end

  test "validates list IDs against catalog and stores warnings" do
    # Create valid list in catalog
    LoopsList.create!(loops_list_id: "valid_list", name: "Valid List")

    sent_payload = nil
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end

    envelope = LoopsOutboxEnvelope.create!(
      email_normalized: @email_normalized,
      payload: {
        "mailingLists" => {
          "value" => { "valid_list" => true, "invalid_list" => true },
          "strategy" => "override",
          "modified_at" => Time.current.iso8601
        }
      },
      status: :queued,
      provenance: build_test_provenance,
      sync_source_id: @sync_source.id
    )

    worker = LoopsDispatchWorker.new
    worker.perform

    # Should send only valid_list, store warning for invalid_list
    assert_equal "partially_sent", envelope.reload.status
    assert_not_nil sent_payload
    assert_equal({ "valid_list" => true }, sent_payload["mailingLists"])

    error = envelope.error
    assert_not_nil error
    assert error.is_a?(Hash)
    assert error["validation_warnings"].present?
    assert_equal [ "invalid_list" ], error["validation_warnings"]["invalid_list_ids"]
  end

  test "marks as ignored_noop when all lists already subscribed" do
    # Create existing subscriptions
    LoopsListSubscription.create!(
      email_normalized: @email_normalized,
      list_id: "list1",
      subscribed_at: 1.hour.ago
    )
    LoopsListSubscription.create!(
      email_normalized: @email_normalized,
      list_id: "list2",
      subscribed_at: 1.hour.ago
    )

    sent_payload = nil
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end

    envelope = LoopsOutboxEnvelope.create!(
      email_normalized: @email_normalized,
      payload: {
        "mailingLists" => {
          "value" => { "list1" => true, "list2" => true },
          "strategy" => "override",
          "modified_at" => Time.current.iso8601
        }
      },
      status: :queued,
      provenance: build_test_provenance,
      sync_source_id: @sync_source.id
    )

    worker = LoopsDispatchWorker.new
    worker.perform

    # Should mark as ignored_noop since all lists already subscribed
    assert_equal "ignored_noop", envelope.reload.status
    assert_nil sent_payload
  end

  test "creates subscription records after successful API call" do
    LoopsList.create!(loops_list_id: "list1", name: "List 1")
    LoopsList.create!(loops_list_id: "list2", name: "List 2")

    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      { "success" => true, "id" => "test-request-123" }
    end

    envelope = LoopsOutboxEnvelope.create!(
      email_normalized: @email_normalized,
      payload: {
        "mailingLists" => {
          "value" => { "list1" => true, "list2" => true },
          "strategy" => "override",
          "modified_at" => Time.current.iso8601
        }
      },
      status: :queued,
      provenance: build_test_provenance,
      sync_source_id: @sync_source.id
    )

    worker = LoopsDispatchWorker.new
    worker.perform

    # Should create subscription records
    subscriptions = LoopsListSubscription.where(email_normalized: @email_normalized)
    assert subscriptions.exists?(list_id: "list1"), "Should have subscription for list1"
    assert subscriptions.exists?(list_id: "list2"), "Should have subscription for list2"

    # Verify they were created
    list1_sub = subscriptions.find_by(list_id: "list1")
    list2_sub = subscriptions.find_by(list_id: "list2")
    assert_not_nil list1_sub
    assert_not_nil list2_sub
  end

  test "creates audit records with list names" do
    list1 = LoopsList.create!(loops_list_id: "list1", name: "List 1")
    LoopsList.create!(loops_list_id: "list2", name: "List 2")

    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      { "success" => true, "id" => "test-request-123" }
    end

    envelope = LoopsOutboxEnvelope.create!(
      email_normalized: @email_normalized,
      payload: {
        "mailingLists" => {
          "value" => { "list1" => true },
          "strategy" => "override",
          "modified_at" => Time.current.iso8601
        }
      },
      status: :queued,
      provenance: build_test_provenance,
      sync_source_id: @sync_source.id
    )

    worker = LoopsDispatchWorker.new
    worker.perform

    # Should create audit record
    audit = LoopsContactChangeAudit.find_by(
      email_normalized: @email_normalized,
      field_name: "mailingList:list1"
    )
    assert_not_nil audit
    assert_equal "subscribe", audit.strategy
    assert_equal false, audit.former_loops_value
    assert_equal true, audit.new_loops_value

    # Check provenance includes list name
    provenance = audit.provenance
    assert_not_nil provenance["list"]
    assert_equal "list1", provenance["list"]["id"]
    assert_equal "List 1", provenance["list"]["name"]
  end

  test "does not create bulk mailingLists audit entry when individual entries exist" do
    # This test verifies that we don't create duplicate audit entries:
    # - Should create individual mailingList:xxx entries
    # - Should NOT create bulk mailingLists entry

    LoopsList.create!(loops_list_id: "list1", name: "List 1")
    LoopsList.create!(loops_list_id: "list2", name: "List 2")

    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      { "success" => true, "id" => "test-request-123" }
    end

    provenance = build_test_provenance.dup
    provenance["fields"] = [
      {
        "sync_source_field_id" => "fld123",
        "sync_source_field_name" => "Loops List - Test List",
        "derived_to_loops_field" => "mailingLists",
        "mailing_list_ids" => [ "list1", "list2" ]
      }
    ]

    envelope = LoopsOutboxEnvelope.create!(
      email_normalized: @email_normalized,
      payload: {
        "mailingLists" => {
          "value" => { "list1" => true, "list2" => true },
          "strategy" => "override",
          "modified_at" => Time.current.iso8601
        }
      },
      status: :queued,
      provenance: provenance,
      sync_source_id: @sync_source.id
    )

    worker = LoopsDispatchWorker.new
    worker.perform

    # Should create individual audit entries for each list
    audit1 = LoopsContactChangeAudit.find_by(
      email_normalized: @email_normalized,
      field_name: "mailingList:list1"
    )
    audit2 = LoopsContactChangeAudit.find_by(
      email_normalized: @email_normalized,
      field_name: "mailingList:list2"
    )

    assert_not_nil audit1, "Should create audit entry for list1"
    assert_not_nil audit2, "Should create audit entry for list2"

    # Should NOT create bulk mailingLists audit entry
    bulk_audit = LoopsContactChangeAudit.find_by(
      email_normalized: @email_normalized,
      field_name: "mailingLists"
    )
    assert_nil bulk_audit, "Should NOT create bulk mailingLists audit entry - only individual entries should exist"

    # Verify we only have 2 audit entries (one per list)
    all_audits = LoopsContactChangeAudit.where(email_normalized: @email_normalized)
    mailing_list_audits = all_audits.where("field_name LIKE ?", "mailingList%")
    assert_equal 2, mailing_list_audits.count, "Should have exactly 2 mailing list audit entries (one per list)"
  end

  test "validates default list when added by safety net or initial payload" do
    # This test verifies that the default list is validated even when added
    # by the safety net or initial_payload_for_new_contact, preventing
    # subscriptions to invalid lists when loops_lists catalog is empty

    # Set default list ID
    original_default = ENV["DEFAULT_LOOPS_LIST_ID"]
    ENV["DEFAULT_LOOPS_LIST_ID"] = "default_list_not_in_catalog"

    # Ensure catalog is empty (simulating fresh DB before SyncLoopsListsWorker runs)
    LoopsList.destroy_all

    # Ensure contact doesn't exist (no baselines)
    LoopsFieldBaseline.destroy_all

    sent_payload = nil
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end
    LoopsService.define_singleton_method(:find_contact) do |email: nil, userId: nil|
      []
    end

    envelope = LoopsOutboxEnvelope.create!(
      email_normalized: @email_normalized,
      payload: {
        "firstName" => {
          "value" => "Test",
          "strategy" => "upsert",
          "modified_at" => Time.current.iso8601
        }
      },
      status: :queued,
      provenance: build_test_provenance,
      sync_source_id: @sync_source.id
    )

    worker = LoopsDispatchWorker.new
    worker.perform

    # Should NOT send default list because it's not in catalog
    envelope.reload
    assert_includes [ "sent", "partially_sent" ], envelope.status, "Should send other fields successfully"

    # Verify default list was NOT sent to Loops API
    assert_not_nil sent_payload
    assert_nil sent_payload["mailingLists"], "Default list should NOT be sent if not in catalog"

    # Verify no subscription was created
    subscription = LoopsListSubscription.find_by(
      email_normalized: @email_normalized,
      list_id: "default_list_not_in_catalog"
    )
    assert_nil subscription, "Should NOT create subscription for invalid list ID"

    # Restore original default
    if original_default
      ENV["DEFAULT_LOOPS_LIST_ID"] = original_default
    else
      ENV.delete("DEFAULT_LOOPS_LIST_ID")
    end
  end

  test "syncs catalog when empty before validation" do
    # This test verifies that SyncLoopsListsWorker is called synchronously
    # when the catalog is empty, ensuring validation has data to work with

    # Ensure catalog is empty
    LoopsList.destroy_all

    # Ensure contact doesn't exist (no baselines)
    LoopsFieldBaseline.destroy_all

    # Mock SyncLoopsListsWorker to track calls
    sync_called = false
    original_perform = SyncLoopsListsWorker.instance_method(:perform)
    SyncLoopsListsWorker.define_method(:perform) do
      sync_called = true
      # Create a test list in the catalog
      LoopsList.create!(
        loops_list_id: "test_list_123",
        name: "Test List",
        synced_at: Time.current
      )
    end

    sent_payload = nil
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end

    envelope = LoopsOutboxEnvelope.create!(
      email_normalized: @email_normalized,
      payload: {
        "mailingLists" => {
          "value" => { "test_list_123" => true },
          "strategy" => "override",
          "modified_at" => Time.current.iso8601
        }
      },
      status: :queued,
      provenance: build_test_provenance,
      sync_source_id: @sync_source.id
    )

    worker = LoopsDispatchWorker.new
    worker.perform

    # Verify sync was called
    assert sync_called, "SyncLoopsListsWorker should be called when catalog is empty"

    # Verify list was synced
    assert LoopsList.exists?(loops_list_id: "test_list_123"), "List should be in catalog after sync"

    # Verify envelope was processed successfully
    envelope.reload
    assert_equal "sent", envelope.status

    # Verify subscription was created
    subscription = LoopsListSubscription.find_by(
      email_normalized: @email_normalized,
      list_id: "test_list_123"
    )
    assert_not_nil subscription, "Subscription should be created for valid list"

    # Restore original method
    SyncLoopsListsWorker.define_method(:perform, original_perform)
  end

  test "always creates audit log when subscription is created" do
    # This test verifies that every subscription creation results in an audit log
    # This is a critical data integrity requirement

    # Use a unique email to avoid conflicts with other tests
    unique_email = "audit-test-#{Time.now.to_i}@example.com"
    unique_email_normalized = EmailNormalizer.normalize(unique_email)

    LoopsList.create!(loops_list_id: "list1", name: "List 1")
    LoopsList.create!(loops_list_id: "list2", name: "List 2")

    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      { "success" => true, "id" => "test-request-123" }
    end

    envelope = LoopsOutboxEnvelope.create!(
      email_normalized: unique_email_normalized,
      payload: {
        "mailingLists" => {
          "value" => { "list1" => true, "list2" => true },
          "strategy" => "override",
          "modified_at" => Time.current.iso8601
        }
      },
      status: :queued,
      provenance: build_test_provenance,
      sync_source_id: @sync_source.id
    )

    worker = LoopsDispatchWorker.new
    worker.perform

    # Verify subscriptions were created
    subscriptions = LoopsListSubscription.where(email_normalized: unique_email_normalized)
    assert_equal 2, subscriptions.count, "Should have 2 subscriptions"

    # Verify audit logs were created for each subscription
    subscriptions.each do |subscription|
      audit = LoopsContactChangeAudit.find_by(
        email_normalized: unique_email_normalized,
        field_name: "mailingList:#{subscription.list_id}"
      )
      assert_not_nil audit, "Should have audit log for subscription to #{subscription.list_id}"
      assert_equal "subscribe", audit.strategy
      assert_equal true, audit.new_loops_value
      assert_equal false, audit.former_loops_value
    end
  end

  test "creates audit log for default list when added by safety net" do
    # This test verifies that default list subscriptions get audit logs
    # even when they're added by the safety net (not from envelope)

    original_default = ENV["DEFAULT_LOOPS_LIST_ID"]
    ENV["DEFAULT_LOOPS_LIST_ID"] = "default_list_123"
    LoopsList.create!(loops_list_id: "default_list_123", name: "Default List")

    # Use a unique email to avoid conflicts
    unique_email = "default-test-#{Time.now.to_i}@example.com"
    unique_email_normalized = EmailNormalizer.normalize(unique_email)

    # Ensure contact doesn't exist (no baselines)
    LoopsFieldBaseline.where(email_normalized: unique_email_normalized).destroy_all

    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      { "success" => true, "id" => "test-request-123" }
    end

    # Create envelope WITHOUT mailingLists (to trigger safety net)
    envelope = LoopsOutboxEnvelope.create!(
      email_normalized: unique_email_normalized,
      payload: {
        "firstName" => {
          "value" => "Test",
          "strategy" => "upsert",
          "modified_at" => Time.current.iso8601
        }
      },
      status: :queued,
      provenance: build_test_provenance,
      sync_source_id: @sync_source.id
    )

    worker = LoopsDispatchWorker.new
    worker.perform

    # Verify subscription was created
    subscription = LoopsListSubscription.find_by(
      email_normalized: unique_email_normalized,
      list_id: "default_list_123"
    )
    assert_not_nil subscription, "Default list subscription should be created"

    # Verify audit log was created
    audit = LoopsContactChangeAudit.find_by(
      email_normalized: unique_email_normalized,
      field_name: "mailingList:default_list_123"
    )
    assert_not_nil audit, "Should have audit log for default list subscription"
    assert_equal "subscribe", audit.strategy
    assert_equal true, audit.new_loops_value

    # Restore original default
    if original_default
      ENV["DEFAULT_LOOPS_LIST_ID"] = original_default
    else
      ENV.delete("DEFAULT_LOOPS_LIST_ID")
    end
  end

  test "handles audit log creation failure gracefully without losing subscription" do
    # This test verifies that if audit log creation fails,
    # the subscription is still created and the error is logged

    LoopsList.create!(loops_list_id: "list1", name: "List 1")

    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      { "success" => true, "id" => "test-request-123" }
    end

    # Mock audit log creation to fail
    original_create = LoopsContactChangeAudit.method(:create!)
    LoopsContactChangeAudit.define_singleton_method(:create!) do |**kwargs|
      if kwargs[:field_name]&.start_with?("mailingList:")
        raise StandardError, "Simulated audit log creation failure"
      end
      original_create.call(**kwargs)
    end

    envelope = LoopsOutboxEnvelope.create!(
      email_normalized: @email_normalized,
      payload: {
        "mailingLists" => {
          "value" => { "list1" => true },
          "strategy" => "override",
          "modified_at" => Time.current.iso8601
        }
      },
      status: :queued,
      provenance: build_test_provenance,
      sync_source_id: @sync_source.id
    )

    worker = LoopsDispatchWorker.new

    # Should not raise exception - subscription should be created despite audit failure
    assert_nothing_raised do
      worker.perform
    end

    # Verify subscription was created despite audit log failure
    subscription = LoopsListSubscription.find_by(
      email_normalized: @email_normalized,
      list_id: "list1"
    )
    assert_not_nil subscription, "Subscription should be created even if audit log fails"

    # Verify audit log was NOT created (because we made it fail)
    audit = LoopsContactChangeAudit.find_by(
      email_normalized: @email_normalized,
      field_name: "mailingList:list1"
    )
    assert_nil audit, "Audit log should not exist because creation failed"

    # Restore original method
    LoopsContactChangeAudit.define_singleton_method(:create!, original_create)
  end
end
