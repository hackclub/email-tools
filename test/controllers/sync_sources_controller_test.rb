require "test_helper"
require "minitest/mock"

class SyncSourcesControllerTest < ActionDispatch::IntegrationTest
  def setup
    @username = "test_admin"
    @password = "test_password"
    ENV["ADMIN_USERNAME"] = @username
    ENV["ADMIN_PASSWORD"] = @password
    # Clean up in correct order to respect foreign keys
    LoopsOutboxEnvelope.destroy_all if defined?(LoopsOutboxEnvelope)
    FieldValueBaseline.destroy_all if defined?(FieldValueBaseline)
    SyncSource.destroy_all
    SyncSourceIgnore.destroy_all
  end

  def teardown
    ENV.delete("ADMIN_USERNAME")
    ENV.delete("ADMIN_PASSWORD")
    # Clean up in correct order to respect foreign keys
    LoopsOutboxEnvelope.destroy_all if defined?(LoopsOutboxEnvelope)
    FieldValueBaseline.destroy_all if defined?(FieldValueBaseline)
    SyncSource.destroy_all
    SyncSourceIgnore.destroy_all
  end

  def auth_headers
    credentials = ActionController::HttpAuthentication::Basic.encode_credentials(@username, @password)
    { "HTTP_AUTHORIZATION" => credentials }
  end

  test "ignore action creates ignore record" do
    post admin_sync_sources_ignore_path, params: { source: "airtable", source_id: "^base123$" }, headers: auth_headers

    assert_redirected_to admin_sync_sources_path(source: "airtable")
    assert SyncSourceIgnore.exists?(source: "airtable", source_id: "^base123$")
  end

  test "ignore action soft deletes matching sync source if exists" do
    existing = SyncSource.create!(
      source: "airtable",
      source_id: "base123",
      display_name: "Test Base"
    )

    post admin_sync_sources_ignore_path, params: { source: "airtable", source_id: "^base123$" }, headers: auth_headers

    assert_redirected_to admin_sync_sources_path(source: "airtable")
    assert SyncSourceIgnore.exists?(source: "airtable", source_id: "^base123$")
    # Should be soft-deleted (not in default scope)
    assert_nil SyncSource.find_by(id: existing.id)
    # But should exist in with_deleted scope
    deleted = SyncSource.with_deleted.find_by(id: existing.id)
    assert_not_nil deleted
    assert_not_nil deleted.deleted_at
    assert_equal "ignored_pattern", deleted.deleted_reason
  end

  test "unignore action removes ignore record" do
    ignore = SyncSourceIgnore.create!(source: "airtable", source_id: "^base123$")
    assert SyncSourceIgnore.exists?(source: "airtable", source_id: "^base123$"), "Precondition: ignore record should exist"

    # DELETE with params in body (Rails integration tests handle this correctly)
    delete admin_sync_sources_unignore_path, params: { source: "airtable", ignore_id: ignore.id }, headers: auth_headers

    assert_redirected_to admin_sync_sources_path(source: "airtable")
    assert_not SyncSourceIgnore.exists?(id: ignore.id), "Ignore record should be deleted"
  end

  test "ignore action creates pattern ignore" do
    post admin_sync_sources_ignore_path, params: {
      source: "airtable",
      pattern: "^app.*"
    }, headers: auth_headers

    assert_redirected_to admin_sync_sources_path(source: "airtable")
    pattern_ignore = SyncSourceIgnore.find_by(source: "airtable", source_id: "^app.*")
    assert_not_nil pattern_ignore
  end

  test "ignore action validates pattern regex" do
    post admin_sync_sources_ignore_path, params: {
      source: "airtable",
      pattern: "[invalid"
    }, headers: auth_headers

    assert_redirected_to admin_sync_sources_path(source: "airtable")
    assert_not SyncSourceIgnore.exists?(source: "airtable", source_id: "[invalid")
  end

  test "ignore action soft deletes all matching sync sources" do
    matching1 = SyncSource.create!(
      source: "airtable",
      source_id: "app123",
      display_name: "App Base"
    )
    matching2 = SyncSource.create!(
      source: "airtable",
      source_id: "app456",
      display_name: "Another App"
    )
    non_matching = SyncSource.create!(
      source: "airtable",
      source_id: "base789",
      display_name: "Non-Matching Base"
    )

    post admin_sync_sources_ignore_path, params: {
      source: "airtable",
      pattern: "^app.*"
    }, headers: auth_headers

    assert_redirected_to admin_sync_sources_path(source: "airtable")
    # Matching sources should be soft-deleted
    assert_nil SyncSource.find_by(id: matching1.id)
    assert_nil SyncSource.find_by(id: matching2.id)
    deleted1 = SyncSource.with_deleted.find_by(id: matching1.id)
    assert_equal "ignored_pattern", deleted1.deleted_reason
    # Non-matching source should remain active
    assert_not_nil SyncSource.find_by(id: non_matching.id)
  end

  test "ignore action with exact match uses anchored regex" do
    post admin_sync_sources_ignore_path, params: {
      source: "airtable",
      source_id: "^base123$"
    }, headers: auth_headers

    assert_redirected_to admin_sync_sources_path(source: "airtable")
    ignore = SyncSourceIgnore.find_by(source: "airtable", source_id: "^base123$")
    assert_not_nil ignore
    assert ignore.matches?("base123")
    assert_not ignore.matches?("base1234")
  end

  test "unignore action removes pattern ignore by id" do
    pattern_ignore = SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^app.*"
    )

    delete admin_sync_sources_unignore_path, params: {
      source: "airtable",
      ignore_id: pattern_ignore.id
    }, headers: auth_headers

    assert_redirected_to admin_sync_sources_path(source: "airtable")
    assert_nil SyncSourceIgnore.find_by(id: pattern_ignore.id)
  end

  test "index action handles pathological regex patterns without hanging" do
    # Create a pattern that could cause DoS
    pathological_pattern = "(a+)+$"
    SyncSourceIgnore.create!(
      source: "airtable",
      source_id: pathological_pattern
    )

    # Mock adapter to avoid actual API call
    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "base1", name: "Base One" },
      { id: "a" * 50 + "b", name: "Test Base" }
    ]

    Discovery::AirtableAdapter.stub :new, adapter do
      start_time = Time.current
      get admin_sync_sources_path(source: "airtable"), headers: auth_headers
      elapsed = Time.current - start_time

      assert_response :success
      # Should complete quickly despite pathological pattern (timeout protects us)
      assert elapsed < 1.0, "Index should load quickly even with pathological regex (took #{elapsed}s)"
    end
  end

  test "index action requires source parameter" do
    get admin_sync_sources_path, headers: auth_headers

    assert_response :success
    assert_match(/Source parameter is required/, response.body)
    assert_match(/Select a source type/, response.body)
  end

  test "index action uses source parameter when provided" do
    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "base1", name: "Base One" }
    ]

    Discovery::AirtableAdapter.stub :new, adapter do
      get admin_sync_sources_path(source: "airtable"), headers: auth_headers

      assert_response :success
      assert_match(/Sync Sources/, response.body)
      adapter.verify
    end
  end

  test "index action renders generic labels instead of Airtable-specific ones" do
    adapter = Minitest::Mock.new
    adapter.expect :list_ids_with_names, [
      { id: "base1", name: "Base One" }
    ]

    Discovery::AirtableAdapter.stub :new, adapter do
      get admin_sync_sources_path(source: "airtable"), headers: auth_headers

      assert_response :success
      # Check for generic labels
      assert_match(/Source ID/, response.body)
      assert_match(/Name/, response.body)
      # Note: "Ignored / Deleted Sources" section only appears if there are deleted sources
      # Should not contain Airtable-specific labels
      assert_no_match(/Base Name/, response.body)
      assert_no_match(/Base ID/, response.body)
      assert_no_match(/Ignored Bases/, response.body)
    end
  end

  test "show action renders generic labels instead of Airtable-specific ones" do
    sync_source = SyncSource.create!(
      source: "airtable",
      source_id: "base123",
      display_name: "Test Base"
    )

    get admin_sync_source_path(sync_source), headers: auth_headers

    assert_response :success
    # Check for generic label
    assert_match(/Source ID/, response.body)
    # Should not contain Airtable-specific label
    assert_no_match(/Base ID/, response.body)
  end

  test "ignore action redirects with source parameter preserved" do
    post admin_sync_sources_ignore_path, params: { source: "airtable", source_id: "^base123$" }, headers: auth_headers

    assert_redirected_to admin_sync_sources_path(source: "airtable")
    assert SyncSourceIgnore.exists?(source: "airtable", source_id: "^base123$")
  end

  test "unignore action redirects with source parameter preserved" do
    ignore = SyncSourceIgnore.create!(source: "airtable", source_id: "^base123$")

    delete admin_sync_sources_unignore_path, params: { source: "airtable", ignore_id: ignore.id }, headers: auth_headers

    assert_redirected_to admin_sync_sources_path(source: "airtable")
    assert_not SyncSourceIgnore.exists?(id: ignore.id)
  end

  test "ignore action only soft deletes sources matching the new pattern" do
    # Create an existing ignore pattern P1 and a matching source S1 (manually re-activated)
    existing_pattern = SyncSourceIgnore.create!(
      source: "airtable",
      source_id: "^old.*"
    )

    s1 = SyncSource.create!(
      source: "airtable",
      source_id: "old123",
      display_name: "Old Base"
    )
    # Manually restore S1 (simulating a previously ignored source that was restored)
    s1.restore! if s1.deleted_at.present?

    # Create source S2 that will match the new pattern P2
    s2 = SyncSource.create!(
      source: "airtable",
      source_id: "new456",
      display_name: "New Base"
    )

    # Add a new pattern P2 matching source S2
    post admin_sync_sources_ignore_path, params: {
      source: "airtable",
      pattern: "^new.*"
    }, headers: auth_headers

    assert_redirected_to admin_sync_sources_path(source: "airtable")

    # Verify only S2 is deleted (matches new pattern P2)
    assert_nil SyncSource.find_by(id: s2.id), "S2 should be soft-deleted by new pattern"
    deleted_s2 = SyncSource.with_deleted.find_by(id: s2.id)
    assert_not_nil deleted_s2
    assert_equal "ignored_pattern", deleted_s2.deleted_reason

    # Verify S1 is NOT deleted (matches old pattern P1, but should not be affected)
    assert_not_nil SyncSource.find_by(id: s1.id), "S1 should remain active (matches old pattern, not new one)"

    # Verify both patterns exist
    assert SyncSourceIgnore.exists?(source: "airtable", source_id: "^old.*")
    assert SyncSourceIgnore.exists?(source: "airtable", source_id: "^new.*")
  end

  test "ignore action completes quickly with many sync sources" do
    # Create 10,000+ sync sources
    source_ids = (1..10000).map { |i| "base#{i}" }
    source_ids.each do |source_id|
      SyncSource.create!(
        source: "airtable",
        source_id: source_id,
        display_name: "Base #{source_id}"
      )
    end

    # Create a pattern that matches a subset (base1 through base9)
    expected_matching_ids = (1..9).map { |i| "base#{i}" }

    start_time = Time.current
    post admin_sync_sources_ignore_path, params: {
      source: "airtable",
      pattern: "^base[1-9]$"
    }, headers: auth_headers
    elapsed = Time.current - start_time

    assert_redirected_to admin_sync_sources_path(source: "airtable")
    # Should complete quickly (under 5 seconds) even with 10,000+ records
    assert elapsed < 5.0, "Ignore action should complete quickly with many records (took #{elapsed}s)"

    # Verify matching sources were deleted (should be 9: base1 through base9)
    expected_matching_ids.each do |source_id|
      deleted = SyncSource.with_deleted.find_by(source: "airtable", source_id: source_id)
      assert_not_nil deleted, "Source #{source_id} should be deleted"
      assert_not_nil deleted.deleted_at, "Source #{source_id} should have deleted_at set"
      assert_equal "ignored_pattern", deleted.deleted_reason, "Source #{source_id} should have correct deleted_reason"
    end

    # Verify non-matching sources remain active (base10 and above)
    non_matching = SyncSource.find_by(source: "airtable", source_id: "base10")
    assert_not_nil non_matching, "base10 should remain active"
    assert_nil non_matching.deleted_at, "base10 should not be deleted"

    # Verify total counts
    deleted_count = SyncSource.with_deleted.where(
      source: "airtable",
      deleted_reason: "ignored_pattern"
    ).count
    assert_equal 9, deleted_count, "Should have deleted exactly 9 matching sources"

    active_count = SyncSource.where(source: "airtable").count
    assert_equal 9991, active_count, "Should have 9991 active sources remaining"
  end
end
