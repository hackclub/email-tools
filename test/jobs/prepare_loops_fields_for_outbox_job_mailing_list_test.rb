require "test_helper"
require "minitest/mock"

class PrepareLoopsFieldsForOutboxJobMailingListTest < ActiveJob::TestCase
  parallelize(workers: 1)

  def setup
    @sync_source = SyncSource.create!(
      source: "airtable",
      source_id: "app123",
      poll_interval_seconds: 30
    )

    @email = "test@example.com"
    @table_id = "tbl123"
    @record_id = "rec123"
    @list_field_key = "fld1/Loops List - Any Notes"

    LoopsOutboxEnvelope.destroy_all
  end

  def teardown
    LoopsOutboxEnvelope.destroy_all
    SyncSource.destroy_all
  end

  test "parses comma-separated list IDs into mailingLists envelope" do
    changed_fields = {
      @list_field_key => {
        "value" => "list1,list2,list3",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    envelope = LoopsOutboxEnvelope.last
    assert_not_nil envelope
    assert envelope.payload.key?("mailingLists"), "Payload should have mailingLists key. Payload: #{envelope.payload.inspect}"

    mailing_lists = envelope.payload["mailingLists"]
    assert_not_nil mailing_lists, "mailingLists should not be nil"

    # JSONB stores keys as strings, so check both string and symbol access
    strategy = mailing_lists[:strategy] || mailing_lists["strategy"]
    value = mailing_lists[:value] || mailing_lists["value"]

    assert_equal "override", strategy.to_s, "Strategy should be override"
    assert_equal({ "list1" => true, "list2" => true, "list3" => true }, value)
  end

  test "handles whitespace in comma-separated list IDs" do
    changed_fields = {
      @list_field_key => {
        "value" => "list1, list2 , list3",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    envelope = LoopsOutboxEnvelope.last
    mailing_lists = envelope.payload["mailingLists"]
    value = mailing_lists[:value] || mailing_lists["value"]
    assert_equal({ "list1" => true, "list2" => true, "list3" => true }, value)
  end

  test "removes duplicate list IDs" do
    changed_fields = {
      @list_field_key => {
        "value" => "list1,list2,list1,list3",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    envelope = LoopsOutboxEnvelope.last
    mailing_lists = envelope.payload["mailingLists"]
    value = mailing_lists[:value] || mailing_lists["value"]
    assert_equal({ "list1" => true, "list2" => true, "list3" => true }, value)
  end

  test "merges multiple list fields into single mailingLists entry" do
    changed_fields = {
      "fld1/Loops List - Any Notes" => {
        "value" => "list1,list2",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      },
      "fld2/Loops List - 3 Cool Things" => {
        "value" => "list2,list3",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    envelope = LoopsOutboxEnvelope.last
    assert_not_nil envelope
    mailing_lists = envelope.payload["mailingLists"]
    assert_not_nil mailing_lists, "mailingLists should exist. Payload: #{envelope.payload.inspect}"
    value = mailing_lists[:value] || mailing_lists["value"]
    # Should merge all unique IDs
    assert_equal({ "list1" => true, "list2" => true, "list3" => true }, value)
  end

  test "skips blank list field values" do
    changed_fields = {
      @list_field_key => {
        "value" => "",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    envelope = LoopsOutboxEnvelope.last
    assert_nil envelope, "Should not create envelope for blank list field"
  end

  test "includes mailing_list_ids in provenance" do
    changed_fields = {
      @list_field_key => {
        "value" => "list1,list2",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    envelope = LoopsOutboxEnvelope.last
    field_provenance = envelope.provenance["fields"]&.first

    assert_not_nil field_provenance
    assert_equal "mailingLists", field_provenance["derived_to_loops_field"]
    assert_equal [ "list1", "list2" ], field_provenance["mailing_list_ids"]
  end

  test "handles single list ID" do
    changed_fields = {
      @list_field_key => {
        "value" => "list1",
        "old_value" => nil,
        "modified_at" => Time.current.iso8601
      }
    }

    PrepareLoopsFieldsForOutboxJob.new.perform(
      @email,
      @sync_source.id,
      @table_id,
      @record_id,
      changed_fields
    )

    envelope = LoopsOutboxEnvelope.last
    assert_not_nil envelope
    mailing_lists = envelope.payload["mailingLists"]
    assert_not_nil mailing_lists, "mailingLists should exist. Payload: #{envelope.payload.inspect}"
    value = mailing_lists[:value] || mailing_lists["value"]
    assert_equal({ "list1" => true }, value)
  end
end
