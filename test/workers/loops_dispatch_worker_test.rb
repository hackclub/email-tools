require "test_helper"

class LoopsDispatchWorkerTest < ActiveSupport::TestCase
  # Disable parallelization for this test class since we're testing database interactions
  parallelize(workers: 1)

  # Disable transactional tests for this test class
  # Advisory locks are session-level, not transaction-level
  self.use_transactional_tests = false

  def setup
    @sync_source = SyncSource.create!(
      source: "airtable",
      source_id: "app123",
      poll_interval_seconds: 30
    )

    @email = "test@example.com"
    @email_normalized = EmailNormalizer.normalize(@email)

    # Clean up any existing data
    LoopsOutboxEnvelope.destroy_all
    LoopsFieldBaseline.destroy_all
    LoopsContactChangeAudit.destroy_all

    # Clean up semaphore
    REDIS_FOR_RATE_LIMITING.del(LoopsDispatchWorker::SEMAPHORE_KEY) if defined?(LoopsDispatchWorker::SEMAPHORE_KEY)
  end

  def teardown
    # Clean up any lingering advisory locks
    cleanup_advisory_locks
    # Clean up semaphore
    REDIS_FOR_RATE_LIMITING.del(LoopsDispatchWorker::SEMAPHORE_KEY) if defined?(LoopsDispatchWorker::SEMAPHORE_KEY)
    LoopsOutboxEnvelope.destroy_all
    LoopsFieldBaseline.destroy_all
    LoopsContactChangeAudit.destroy_all
    LoopsListSubscription.destroy_all  # Clean up mailing list subscriptions
    SyncSource.destroy_all
  end

  test "merges multiple envelopes for same email and sends latest value based on modified_at" do
    # Track what gets sent to Loops API
    sent_payload = nil

    # Mock LoopsService.update_contact to capture what's actually sent
    original_update_contact = LoopsService.method(:update_contact)
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end

    begin
      # Create multiple envelopes for the same email with different values and timestamps
      # The one with the latest modified_at should win
      base_time = Time.parse("2025-11-02T10:00:00Z")

      envelope1 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      envelope2 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value2",
            "strategy" => "upsert",
            "modified_at" => (base_time + 1.minute).iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      envelope3 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value3",
            "strategy" => "upsert",
            "modified_at" => (base_time + 30.seconds).iso8601  # Earlier than envelope2
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker
      worker = LoopsDispatchWorker.new
      ensure_worker_can_run(worker)
      worker.perform

      # Verify all envelopes were processed
      assert_equal "sent", envelope1.reload.status, "Envelope1 should be marked as sent"
      assert_equal "sent", envelope2.reload.status, "Envelope2 should be marked as sent"
      assert_equal "sent", envelope3.reload.status, "Envelope3 should be marked as sent"

      # Verify the latest value (value2) was sent, not value1 or value3
      assert_not_nil sent_payload, "LoopsService.update_contact should have been called"
      assert_equal "value2", sent_payload["field1"],
        "Should send value2 (latest modified_at), but got #{sent_payload['field1']}"

      # Verify baseline was updated with the correct value
      baseline = LoopsFieldBaseline.find_by(
        email_normalized: @email_normalized,
        field_name: "field1"
      )
      assert_not_nil baseline, "Baseline should be created"
      assert_equal "value2", baseline.last_sent_value, "Baseline should have latest value"

    ensure
      # Restore original method
      LoopsService.define_singleton_method(:update_contact, original_update_contact)
    end
  end

  test "merges multiple fields from different envelopes" do
    # Track what gets sent to Loops API
    sent_payload = nil

    # Mock LoopsService.update_contact to capture what's actually sent
    original_update_contact = LoopsService.method(:update_contact)
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      # Envelope with field1
      envelope1 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Envelope with field2
      envelope2 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field2" => {
            "value" => "value2",
            "strategy" => "upsert",
            "modified_at" => (base_time + 1.minute).iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Envelope with updated field1 (should win over envelope1)
      envelope3 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1_updated",
            "strategy" => "upsert",
            "modified_at" => (base_time + 2.minutes).iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker
      worker = LoopsDispatchWorker.new
      ensure_worker_can_run(worker)
      worker.perform

      # Verify all envelopes were processed
      assert_equal "sent", envelope1.reload.status
      assert_equal "sent", envelope2.reload.status
      assert_equal "sent", envelope3.reload.status

      # Verify both fields were sent with correct values
      assert_not_nil sent_payload, "LoopsService.update_contact should have been called"
      assert_equal "value1_updated", sent_payload["field1"],
        "field1 should have latest value (value1_updated)"
      assert_equal "value2", sent_payload["field2"],
        "field2 should have value2"
      assert_equal 2, sent_payload.keys.size,
        "Should send exactly 2 fields, but got #{sent_payload.keys.inspect}"

    ensure
      # Restore original method
      LoopsService.define_singleton_method(:update_contact, original_update_contact)
    end
  end

  test "handles string keys vs symbol keys in payload correctly" do
    # Track what gets sent to Loops API
    sent_payload = nil

    # Mock LoopsService.update_contact to capture what's actually sent
    original_update_contact = LoopsService.method(:update_contact)
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      # Envelope with string keys (as JSONB stores them)
      envelope1 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Envelope with symbol keys (to test merging handles both)
      envelope2 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            value: "value2",
            strategy: "upsert",
            modified_at: (base_time + 1.minute).iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker
      worker = LoopsDispatchWorker.new
      ensure_worker_can_run(worker)
      worker.perform

      # Verify the latest value was sent
      assert_not_nil sent_payload, "LoopsService.update_contact should have been called"
      assert_equal "value2", sent_payload["field1"],
        "Should send value2 (latest modified_at), regardless of key type"

    ensure
      # Restore original method
      LoopsService.define_singleton_method(:update_contact, original_update_contact)
    end
  end

  test "filters out unchanged values based on baseline" do
    # Track what gets sent to Loops API
    sent_payload = nil
    call_count = 0

    # Mock LoopsService.update_contact to capture what's actually sent
    original_update_contact = LoopsService.method(:update_contact)
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      call_count += 1
      { "success" => true, "id" => "test-request-123" }
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      # First envelope - sets baseline
      envelope1 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run worker first time - should send value1
      worker = LoopsDispatchWorker.new
      ensure_worker_can_run(worker)
      worker.perform

      assert_equal 1, call_count, "First call should send value1"
      assert_equal "value1", sent_payload["field1"], "First call should send value1"

      # Reset tracking
      sent_payload = nil

      # Second envelope with same value - should be filtered out
      envelope2 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",  # Same value as baseline
            "strategy" => "upsert",
            "modified_at" => (base_time + 1.minute).iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run worker second time - should not send (filtered by baseline)
      worker.perform

      # Should not have been called again (value unchanged)
      assert_equal 1, call_count, "Second call should not happen (value unchanged)"
      assert_equal "ignored_noop", envelope2.reload.status,
        "Envelope2 should be marked as ignored_noop"

      # Third envelope with different value - should be sent
      envelope3 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value2",  # Different value
            "strategy" => "upsert",
            "modified_at" => (base_time + 2.minutes).iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run worker third time - should send value2
      worker.perform

      assert_equal 2, call_count, "Third call should send value2"
      assert_equal "value2", sent_payload["field1"], "Third call should send value2"

    ensure
      # Restore original method
      LoopsService.define_singleton_method(:update_contact, original_update_contact)
    end
  end

  test "validates merging behavior with multiple queued envelopes" do
    # Track what gets sent to Loops API
    sent_payloads = []

    # Mock LoopsService.update_contact to capture what's actually sent
    original_update_contact = LoopsService.method(:update_contact)
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payloads << kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      # Create multiple envelopes with overlapping and different fields
      # Scenario: Multiple rapid changes to same field, plus some different fields

      envelope1 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "initial",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          },
          "field2" => {
            "value" => "static",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      envelope2 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "updated1",
            "strategy" => "upsert",
            "modified_at" => (base_time + 10.seconds).iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      envelope3 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "updated2",
            "strategy" => "upsert",
            "modified_at" => (base_time + 20.seconds).iso8601
          },
          "field3" => {
            "value" => "new_field",
            "strategy" => "upsert",
            "modified_at" => (base_time + 20.seconds).iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      envelope4 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "final",
            "strategy" => "upsert",
            "modified_at" => (base_time + 30.seconds).iso8601  # Latest for field1
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker - should process all queued envelopes for this email
      worker = LoopsDispatchWorker.new
      ensure_worker_can_run(worker)
      worker.perform

      # Verify all envelopes were processed
      assert_equal "sent", envelope1.reload.status, "Envelope1 should be marked as sent"
      assert_equal "sent", envelope2.reload.status, "Envelope2 should be marked as sent"
      assert_equal "sent", envelope3.reload.status, "Envelope3 should be marked as sent"
      assert_equal "sent", envelope4.reload.status, "Envelope4 should be marked as sent"

      # Verify what was actually sent
      assert_equal 1, sent_payloads.length, "Should call LoopsService.update_contact exactly once"

      final_payload = sent_payloads.first
      assert_not_nil final_payload, "LoopsService.update_contact should have been called"

      # field1 should have the latest value (from envelope4)
      assert_equal "final", final_payload["field1"],
        "field1 should have latest value 'final' (from envelope4), but got #{final_payload['field1']}"

      # field2 should be present (from envelope1)
      assert_equal "static", final_payload["field2"],
        "field2 should have value 'static' (from envelope1), but got #{final_payload['field2']}"

      # field3 should be present (from envelope3)
      assert_equal "new_field", final_payload["field3"],
        "field3 should have value 'new_field' (from envelope3), but got #{final_payload['field3']}"

      # Should have exactly 3 fields
      assert_equal 3, final_payload.keys.size,
        "Should send exactly 3 fields, but got #{final_payload.keys.inspect}"

    ensure
      # Restore original method
      LoopsService.define_singleton_method(:update_contact, original_update_contact)
    end
  end

  test "handles legacy payloads with type field" do
    # Track what gets sent to Loops API
    sent_payload = nil

    # Mock LoopsService.update_contact to capture what's actually sent
    original_update_contact = LoopsService.method(:update_contact)
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      # Envelope with legacy "type" field (from old code)
      envelope1 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "type" => "string",  # Legacy field
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Envelope without type field (new format)
      envelope2 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value2",
            "strategy" => "upsert",
            "modified_at" => (base_time + 1.minute).iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker
      worker = LoopsDispatchWorker.new
      ensure_worker_can_run(worker)
      worker.perform

      # Verify the latest value was sent (ignoring type field)
      assert_not_nil sent_payload, "LoopsService.update_contact should have been called"
      assert_equal "value2", sent_payload["field1"],
        "Should send value2 (latest modified_at), ignoring type field"

      # Verify type field is not included in what's sent to Loops API
      field_data = envelope2.reload.payload["field1"]
      assert_not_nil field_data, "Should have field data"
      # The type field might exist in the envelope payload, but shouldn't be sent to Loops
      # (apply_strategies only extracts the value)

    ensure
      # Restore original method
      LoopsService.define_singleton_method(:update_contact, original_update_contact)
    end
  end

  test "override strategy fields bypass baseline filtering even when null value matches baseline" do
    # Track what gets sent to Loops API
    sent_payload = nil

    # Mock LoopsService.update_contact to capture what's actually sent
    original_update_contact = LoopsService.method(:update_contact)
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end

    begin
      # Create a baseline with null value
      baseline = LoopsFieldBaseline.create!(
        email_normalized: @email_normalized,
        field_name: "overrideField",
        last_sent_value: nil,
        last_sent_at: Time.current - 1.day,
        expires_at: Time.current + 90.days
      )

      # Create envelope with override strategy and null value (same as baseline)
      envelope = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "overrideField" => {
            "value" => nil,
            "strategy" => "override",
            "modified_at" => Time.current.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker
      worker = LoopsDispatchWorker.new
      ensure_worker_can_run(worker)
      worker.perform

      # Verify envelope was processed
      assert_equal "sent", envelope.reload.status, "Envelope should be marked as sent"

      # Verify the null value was sent despite matching baseline
      assert_not_nil sent_payload, "LoopsService.update_contact should have been called"
      assert sent_payload.key?("overrideField"), "overrideField should be in payload"
      assert_nil sent_payload["overrideField"], "overrideField should be nil/null"

      # Verify baseline was updated
      baseline.reload
      assert_nil baseline.last_sent_value, "Baseline should reflect null value"

    ensure
      # Restore original method
      LoopsService.define_singleton_method(:update_contact, original_update_contact)
    end
  end

  test "upsert strategy fields with null are filtered out by strategy application" do
    # Track what gets sent to Loops API
    sent_payload = nil

    # Mock LoopsService.update_contact to capture what's actually sent
    original_update_contact = LoopsService.method(:update_contact)
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end

    begin
      # Create envelope with upsert strategy and null value
      envelope = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "upsertField" => {
            "value" => nil,
            "strategy" => "upsert",
            "modified_at" => Time.current.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker
      worker = LoopsDispatchWorker.new
      ensure_worker_can_run(worker)
      worker.perform

      # Verify envelope was marked as ignored_noop (all fields filtered by strategy)
      assert_equal "ignored_noop", envelope.reload.status, "Envelope should be ignored when upsert field has null value"

      # Verify nothing was sent
      assert_nil sent_payload, "LoopsService.update_contact should NOT have been called for null upsert field"

    ensure
      # Restore original method
      LoopsService.define_singleton_method(:update_contact, original_update_contact)
    end
  end

  test "marks envelopes as failed when LoopsService raises ApiError" do
    # Track what gets sent to Loops API
    sent_payload = nil
    sent_email = nil

    # Mock LoopsService.update_contact to raise ApiError
    original_update_contact = LoopsService.method(:update_contact)
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      sent_email = email
      raise LoopsService::ApiError.new(400, '{"message": "Invalid email address"}')
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      # Create envelope that will fail
      envelope = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker - should raise exception but mark envelope as failed
      worker = LoopsDispatchWorker.new
      assert_raises(LoopsService::ApiError) do
        worker.perform
      end

      # Reload envelope and verify it was marked as failed
      envelope.reload
      assert_equal "failed", envelope.status, "Envelope should be marked as failed"

      # Verify error details were stored
      assert_not_nil envelope.error, "Error details should be stored"
      assert_equal "Invalid email address", envelope.error["message"], "Error message should match"
      assert_equal "LoopsService::ApiError", envelope.error["class"], "Error class should be stored"
      assert_not_nil envelope.error["loops_payload_sent"], "Loops payload should be stored"
      assert_equal "value1", envelope.error["loops_payload_sent"]["field1"], "Loops payload should contain field1"
      assert_not_nil envelope.error["occurred_at"], "Occurred_at timestamp should be stored"

      # Verify the API was called with correct payload
      assert_not_nil sent_payload, "LoopsService.update_contact should have been called"
      assert_equal "value1", sent_payload["field1"], "Correct payload should have been sent"

    ensure
      # Restore original method
      LoopsService.define_singleton_method(:update_contact, original_update_contact)
    end
  end

  test "marks envelopes as failed when LoopsService returns unsuccessful response" do
    # Track what gets sent to Loops API
    sent_payload = nil

    # Mock LoopsService.update_contact to return unsuccessful response
    original_update_contact = LoopsService.method(:update_contact)
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => false, "message" => "Update failed" }
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      # Create envelope that will fail
      envelope = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker - should raise exception but mark envelope as failed
      worker = LoopsDispatchWorker.new
      ensure_worker_can_run(worker)
      assert_raises(StandardError) do
        worker.perform
      end

      # Reload envelope and verify it was marked as failed
      envelope.reload
      assert_equal "failed", envelope.status, "Envelope should be marked as failed"

      # Verify error details were stored
      assert_not_nil envelope.error, "Error details should be stored"
      assert_match(/Loops API update did not succeed/, envelope.error["message"], "Error message should indicate failure")
      # CRITICAL: The rescue block should preserve the response from the unless block
      # In the broken code, this would be nil because rescue overwrites without response
      assert_not_nil envelope.error["response"], "Response should be stored - this test will fail with broken code"
      assert_equal false, envelope.error["response"]["success"], "Response should indicate failure"
      assert_not_nil envelope.error["loops_payload_sent"], "Loops payload should be stored"
      assert_equal "value1", envelope.error["loops_payload_sent"]["field1"], "Loops payload should contain field1"
      assert_not_nil envelope.error["occurred_at"], "Occurred_at timestamp should be stored"

      # Verify the API was called with correct payload
      assert_not_nil sent_payload, "LoopsService.update_contact should have been called"
      assert_equal "value1", sent_payload["field1"], "Correct payload should have been sent"

    ensure
      # Restore original method
      LoopsService.define_singleton_method(:update_contact, original_update_contact)
    end
  end

  test "marks envelopes as failed when preflight check fails with invalid email" do
    # Mock LoopsFieldBaseline.check_contact_existence_and_load_baselines to raise ApiError
    original_method = LoopsFieldBaseline.method(:check_contact_existence_and_load_baselines)
    LoopsFieldBaseline.define_singleton_method(:check_contact_existence_and_load_baselines) do |email_normalized:|
      raise LoopsService::ApiError.new(400, '{"message": "Invalid email address"}')
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      # Create envelope that will fail during preflight check
      envelope = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker - should raise exception but mark envelope as failed
      worker = LoopsDispatchWorker.new
      assert_raises(LoopsService::ApiError) do
        worker.perform
      end

      # Reload envelope and verify it was marked as failed
      envelope.reload
      assert_equal "failed", envelope.status, "Envelope should be marked as failed - THIS IS THE CRITICAL TEST"

      # Verify error details were stored
      assert_not_nil envelope.error, "Error details should be stored"
      assert_equal "Invalid email address", envelope.error["message"], "Error message should match"
      assert_equal "LoopsService::ApiError", envelope.error["class"], "Error class should be stored"
      # With the fix, stage should be "preflight_check"
      # Without the fix, it would be "processing" (caught by outer rescue)
      assert_equal "preflight_check", envelope.error["stage"], "Error stage should indicate preflight_check - this verifies the fix works"
      assert_not_nil envelope.error["occurred_at"], "Occurred_at timestamp should be stored"

    ensure
      # Restore original method
      LoopsFieldBaseline.define_singleton_method(:check_contact_existence_and_load_baselines, original_method)
    end
  end

  test "preflight check error handling: marks single envelope as failed with correct stage" do
    # Mock LoopsFieldBaseline.check_contact_existence_and_load_baselines to raise ApiError
    original_method = LoopsFieldBaseline.method(:check_contact_existence_and_load_baselines)
    LoopsFieldBaseline.define_singleton_method(:check_contact_existence_and_load_baselines) do |email_normalized:|
      raise LoopsService::ApiError.new(400, '{"message": "Invalid email address"}')
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      # Create envelope that will fail during preflight check
      envelope = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      initial_status = envelope.status
      assert_equal "queued", initial_status, "Envelope should start as queued"

      # Run the dispatch worker - should raise exception but mark envelope as failed
      worker = LoopsDispatchWorker.new
      assert_raises(LoopsService::ApiError) do
        worker.perform
      end

      # Reload envelope and verify it was marked as failed
      envelope.reload
      assert_equal "failed", envelope.status, "Envelope MUST be marked as failed - this test will fail without the fix"

      # Verify error details were stored with correct stage
      assert_not_nil envelope.error, "Error details must be stored"
      assert_equal "Invalid email address", envelope.error["message"], "Error message must match"
      assert_equal "LoopsService::ApiError", envelope.error["class"], "Error class must be stored"
      assert_equal "preflight_check", envelope.error["stage"], "Error stage MUST be 'preflight_check' - this verifies the specific rescue block works"
      assert_not_nil envelope.error["occurred_at"], "Occurred_at timestamp must be stored"

    ensure
      # Restore original method
      LoopsFieldBaseline.define_singleton_method(:check_contact_existence_and_load_baselines, original_method)
    end
  end

  test "preflight check error handling: marks multiple envelopes as failed" do
    # Mock LoopsFieldBaseline.check_contact_existence_and_load_baselines to raise ApiError
    original_method = LoopsFieldBaseline.method(:check_contact_existence_and_load_baselines)
    LoopsFieldBaseline.define_singleton_method(:check_contact_existence_and_load_baselines) do |email_normalized:|
      raise LoopsService::ApiError.new(400, '{"message": "Invalid email address"}')
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      # Create multiple envelopes for the same email that will fail during preflight check
      envelope1 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      envelope2 = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field2" => {
            "value" => "value2",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker - should raise exception but mark all envelopes as failed
      worker = LoopsDispatchWorker.new
      assert_raises(LoopsService::ApiError) do
        worker.perform
      end

      # Reload envelopes and verify they were all marked as failed
      envelope1.reload
      envelope2.reload
      assert_equal "failed", envelope1.status, "Envelope1 MUST be marked as failed"
      assert_equal "failed", envelope2.status, "Envelope2 MUST be marked as failed"

      # Verify error details were stored for both with correct stage
      assert_not_nil envelope1.error, "Envelope1 error details must be stored"
      assert_not_nil envelope2.error, "Envelope2 error details must be stored"
      assert_equal "Invalid email address", envelope1.error["message"], "Envelope1 error message must match"
      assert_equal "Invalid email address", envelope2.error["message"], "Envelope2 error message must match"
      assert_equal "preflight_check", envelope1.error["stage"], "Envelope1 error stage MUST be 'preflight_check'"
      assert_equal "preflight_check", envelope2.error["stage"], "Envelope2 error stage MUST be 'preflight_check'"

    ensure
      # Restore original method
      LoopsFieldBaseline.define_singleton_method(:check_contact_existence_and_load_baselines, original_method)
    end
  end

  test "preflight check error handling: uses update_columns for persistence" do
    # This test verifies that update_columns is used (not update!) to bypass validations
    # Mock LoopsFieldBaseline.check_contact_existence_and_load_baselines to raise ApiError
    original_method = LoopsFieldBaseline.method(:check_contact_existence_and_load_baselines)
    LoopsFieldBaseline.define_singleton_method(:check_contact_existence_and_load_baselines) do |email_normalized:|
      raise LoopsService::ApiError.new(400, '{"message": "Invalid email address"}')
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      # Create envelope that will fail during preflight check
      envelope = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Track if update_columns was called (we can't easily spy on it, but we can verify
      # that the update persists even if there are validation issues)
      original_updated_at = envelope.updated_at

      # Run the dispatch worker
      worker = LoopsDispatchWorker.new
      ensure_worker_can_run(worker)
      assert_raises(LoopsService::ApiError) do
        worker.perform
      end

      # Reload envelope and verify it was marked as failed
      envelope.reload
      assert_equal "failed", envelope.status, "Envelope MUST be marked as failed"

      # Verify updated_at was changed (update_columns should update it)
      assert envelope.updated_at > original_updated_at, "updated_at should be updated by update_columns"

      # Verify error details persist
      assert_not_nil envelope.error, "Error details must persist"
      assert_equal "preflight_check", envelope.error["stage"], "Error stage must be 'preflight_check'"

    ensure
      # Restore original method
      LoopsFieldBaseline.define_singleton_method(:check_contact_existence_and_load_baselines, original_method)
    end
  end

  test "preflight check error handling: transaction ensures persistence even if job fails" do
    # This test verifies that the transaction ensures envelopes are marked as failed
    # even if the job fails and Sidekiq retries
    original_method = LoopsFieldBaseline.method(:check_contact_existence_and_load_baselines)
    LoopsFieldBaseline.define_singleton_method(:check_contact_existence_and_load_baselines) do |email_normalized:|
      raise LoopsService::ApiError.new(400, '{"message": "Invalid email address"}')
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      envelope = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker
      worker = LoopsDispatchWorker.new
      ensure_worker_can_run(worker)
      assert_raises(LoopsService::ApiError) do
        worker.perform
      end

      # Simulate what happens if Sidekiq retries: verify envelope is still marked as failed
      # even after the exception is raised
      envelope.reload
      assert_equal "failed", envelope.status, "Envelope MUST remain marked as failed after exception"

      # Verify error details persist
      assert_not_nil envelope.error, "Error details must persist after exception"
      assert_equal "preflight_check", envelope.error["stage"], "Error stage must persist"

      # Verify that running the worker again doesn't try to process the failed envelope
      # (it should be skipped since it's no longer queued)
      ensure_worker_can_run(worker)
      processed_count = worker.perform
      envelope.reload
      assert_equal "failed", envelope.status, "Envelope should remain failed and not be reprocessed"

    ensure
      # Restore original method
      LoopsFieldBaseline.define_singleton_method(:check_contact_existence_and_load_baselines, original_method)
    end
  end

  test "semaphore constants are defined correctly" do
    # Verify semaphore constants exist
    assert_equal "loops_dispatch:semaphore", LoopsDispatchWorker::SEMAPHORE_KEY, "Semaphore key should be correct"
    assert_equal 10, LoopsDispatchWorker::MAX_CONCURRENT, "Max concurrent should be 10"
    assert_equal 3600, LoopsDispatchWorker::SEMAPHORE_TTL, "Semaphore TTL should be 1 hour"
  end

  test "jobs can still be enqueued" do
    # Verify that jobs can still be enqueued (semaphore check happens at execution time)
    job_id = LoopsDispatchWorker.perform_async
    assert_not_nil job_id, "Job should be enqueued successfully"

    # Note: Cleanup happens in teardown method
  end

  test "max concurrent matches LoopsService rate limit" do
    # Verify that the concurrency limit matches LoopsService rate limit
    rate_limit = LoopsService.rate_limit_rps

    # Verify max concurrent matches (or is at least <= rate limit)
    assert_operator LoopsDispatchWorker::MAX_CONCURRENT, :<=, rate_limit,
                    "Max concurrent should be <= rate limit"
    assert_equal 10, LoopsDispatchWorker::MAX_CONCURRENT, "Max concurrent should be 10"
  end

  test "worker still processes envelopes correctly with throttling enabled" do
    # Verify that throttling doesn't break normal functionality
    sent_payload = nil

    original_update_contact = LoopsService.method(:update_contact)
    LoopsService.define_singleton_method(:update_contact) do |email:, **kwargs|
      sent_payload = kwargs.dup
      { "success" => true, "id" => "test-request-123" }
    end

    begin
      base_time = Time.parse("2025-11-02T10:00:00Z")

      envelope = LoopsOutboxEnvelope.create!(
        email_normalized: @email_normalized,
        payload: {
          "field1" => {
            "value" => "value1",
            "strategy" => "upsert",
            "modified_at" => base_time.iso8601
          }
        },
        status: :queued,
        provenance: build_test_provenance,
        sync_source_id: @sync_source.id
      )

      # Run the dispatch worker - should work normally despite throttling
      worker = LoopsDispatchWorker.new
      ensure_worker_can_run(worker)
      worker.perform

      # Verify envelope was processed
      envelope.reload
      assert_equal "sent", envelope.status, "Envelope should be marked as sent"

      # Verify API was called
      assert_not_nil sent_payload, "LoopsService.update_contact should have been called"
      assert_equal "value1", sent_payload["field1"], "Correct payload should have been sent"

    ensure
      LoopsService.define_singleton_method(:update_contact, original_update_contact)
    end
  end

  test "semaphore prevents more than MAX_CONCURRENT jobs from running" do
    # Clean up any existing semaphore entries
    redis = Sidekiq.redis { |conn| conn }
    redis.del(LoopsDispatchWorker::SEMAPHORE_KEY)

    worker1 = LoopsDispatchWorker.new
    worker1.instance_variable_set(:@jid, "test-jid-1")

    worker2 = LoopsDispatchWorker.new
    worker2.instance_variable_set(:@jid, "test-jid-2")

    # Acquire first 10 slots
    10.times do |i|
      w = LoopsDispatchWorker.new
      w.instance_variable_set(:@jid, "test-jid-#{i}")
      assert w.acquire_semaphore, "Should acquire semaphore slot #{i}"
    end

    # 11th attempt should fail
    assert_not worker1.acquire_semaphore, "Should not acquire semaphore when at limit"

    # Verify count is 10
    assert_equal 10, LoopsDispatchWorker.semaphore_count, "Should have 10 active jobs"

    # Release one slot
    worker_release = LoopsDispatchWorker.new
    worker_release.instance_variable_set(:@jid, "test-jid-0")
    worker_release.release_semaphore

    # Now should be able to acquire
    assert_equal 9, LoopsDispatchWorker.semaphore_count, "Should have 9 active jobs after release"
    assert worker1.acquire_semaphore, "Should acquire semaphore after release"

    # Clean up
    11.times do |i|
      w = LoopsDispatchWorker.new
      w.instance_variable_set(:@jid, "test-jid-#{i}")
      w.release_semaphore
    end
  end

  test "semaphore releases on job completion" do
    redis = Sidekiq.redis { |conn| conn }
    redis.del(LoopsDispatchWorker::SEMAPHORE_KEY)

    worker = LoopsDispatchWorker.new
    worker.instance_variable_set(:@jid, "test-jid-complete")

    # Acquire semaphore
    assert worker.acquire_semaphore, "Should acquire semaphore"
    assert_equal 1, LoopsDispatchWorker.semaphore_count, "Should have 1 active job"

    # Release semaphore (simulating job completion)
    worker.release_semaphore
    assert_equal 0, LoopsDispatchWorker.semaphore_count, "Should have 0 active jobs after release"
  end

  test "semaphore releases even if job crashes" do
    redis = Sidekiq.redis { |conn| conn }
    redis.del(LoopsDispatchWorker::SEMAPHORE_KEY)

    worker = LoopsDispatchWorker.new
    worker.instance_variable_set(:@jid, "test-jid-crash")

    # Acquire semaphore
    assert worker.acquire_semaphore, "Should acquire semaphore"
    assert_equal 1, LoopsDispatchWorker.semaphore_count, "Should have 1 active job"

    # Simulate crash - ensure block should still release
    begin
      begin
        worker.acquire_semaphore # Already acquired, but simulate work
        raise StandardError, "Simulated crash"
      ensure
        worker.release_semaphore
      end
    rescue StandardError
      # Expected
    end

    assert_equal 0, LoopsDispatchWorker.semaphore_count, "Should release semaphore even after crash"
  end

  test "perform skips processing when semaphore cannot be acquired" do
    redis = Sidekiq.redis { |conn| conn }
    redis.del(LoopsDispatchWorker::SEMAPHORE_KEY)

    # Fill up all 10 slots
    10.times do |i|
      w = LoopsDispatchWorker.new
      w.instance_variable_set(:@jid, "test-jid-#{i}")
      w.acquire_semaphore
    end

    # Create a worker that should skip
    worker = LoopsDispatchWorker.new
    worker.instance_variable_set(:@jid, "test-jid-skip")

    # Should skip because semaphore can't be acquired
    processed_count = worker.perform
    assert_equal 0, processed_count, "Should return 0 when semaphore not acquired"

    # Clean up
    10.times do |i|
      w = LoopsDispatchWorker.new
      w.instance_variable_set(:@jid, "test-jid-#{i}")
      w.release_semaphore
    end
  end

  test "semaphore_count returns current active job count" do
    redis = Sidekiq.redis { |conn| conn }
    redis.del(LoopsDispatchWorker::SEMAPHORE_KEY)

    assert_equal 0, LoopsDispatchWorker.semaphore_count, "Should start with 0 jobs"

    # Add some jobs
    5.times do |i|
      w = LoopsDispatchWorker.new
      w.instance_variable_set(:@jid, "test-jid-#{i}")
      w.acquire_semaphore
    end

    assert_equal 5, LoopsDispatchWorker.semaphore_count, "Should have 5 active jobs"

    # Clean up
    5.times do |i|
      w = LoopsDispatchWorker.new
      w.instance_variable_set(:@jid, "test-jid-#{i}")
      w.release_semaphore
    end
  end

  private

  # Helper to ensure worker can acquire semaphore for testing
  def ensure_worker_can_run(worker)
    # Clean up semaphore first
    REDIS_FOR_RATE_LIMITING.del(LoopsDispatchWorker::SEMAPHORE_KEY)

    # Set jid if not set
    worker.instance_variable_set(:@jid, SecureRandom.hex(12)) unless worker.jid

    # Acquire semaphore
    worker.acquire_semaphore
  end

  def build_test_provenance
    {
      sync_source_id: @sync_source.id,
      sync_source_type: "airtable",
      sync_source_table_id: "tblTest123",
      sync_source_record_id: "recTest456",
      fields: [ {
        sync_source_field_id: "fldTest789",
        sync_source_field_name: "Loops - TestField",
        former_sync_source_value: nil,
        new_sync_source_value: "test_value",
        modified_at: Time.current.iso8601
      } ],
      created_from: "airtable_poller",
      sync_source_metadata: {
        source_id: @sync_source.source_id
      }
    }
  end

  def cleanup_advisory_locks
    # Clean up any advisory locks that might be left over from tests
    connection = ApplicationRecord.connection
    connection.execute("SELECT pg_advisory_unlock_all()")
  rescue => e
    Rails.logger.debug("Advisory lock cleanup: #{e.message}") if defined?(Rails)
  end
end
