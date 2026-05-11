require "test_helper"
require "minitest/mock"

class MassUnsubscribeJobTest < ActiveSupport::TestCase
  def setup
    @main_email = "zach@hackclub.com"
    @main_email_normalized = EmailNormalizer.normalize(@main_email)
    @alt_emails = [ "zach+test@hackclub.com", "zach+test2@hackclub.com" ]

    # Clean up audit logs
    LoopsContactChangeAudit.where(email_normalized: [ @main_email_normalized ] + @alt_emails.map { |e| EmailNormalizer.normalize(e) }).delete_all
  end

  def teardown
    LoopsContactChangeAudit.where(email_normalized: [ @main_email_normalized ] + @alt_emails.map { |e| EmailNormalizer.normalize(e) }).delete_all
  end

  test "performs full merge and unsubscribe flow successfully" do
    main_contact = { "email" => @main_email, "firstName" => "Zach", "lastName" => "Latta" }
    alt_contact1 = { "email" => @alt_emails[0], "firstName" => "Zach", "tags" => [ "test" ] }
    alt_contact2 = { "email" => @alt_emails[1], "lastName" => "Latta" }

    merged_fields = {
      "firstName" => "Zach",
      "lastName" => "Latta",
      "tags" => [ "test" ]
    }

    # Mock LoopsService.send_transactional_email to prevent real emails
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      # Mock LoopsService.find_contact
      LoopsService.stub(:find_contact, ->(email:) {
        case email
        when @main_email
          [ main_contact ]
        when @alt_emails[0]
          [ alt_contact1 ]
        when @alt_emails[1]
          [ alt_contact2 ]
        else
          []
        end
      }) do
        # Mock Ai::ContactMergerService
        Ai::ContactMergerService.stub(:call, merged_fields) do
          # Mock LoopsService.update_contact
          update_calls = []
          LoopsService.stub(:update_contact, ->(email:, **kwargs) {
            update_calls << { email: email, kwargs: kwargs }
            { "success" => true, "id" => "test_id_#{update_calls.length}" }
          }) do
            job = MassUnsubscribeJob.new
            job.perform(@main_email, @alt_emails)

            # Verify main contact was updated with merged fields
            main_update = update_calls.find { |c| c[:email] == @main_email }
            assert_not_nil main_update
            assert_equal merged_fields, main_update[:kwargs]

            # Verify alts were unsubscribed
            @alt_emails.each do |alt|
              alt_update = update_calls.find { |c| c[:email] == alt }
              assert_not_nil alt_update
              assert_equal false, alt_update[:kwargs][:subscribed]
            end
          end
        end
      end
    end
  end

  test "creates individual audit logs for each merged field" do
    main_contact = { "email" => @main_email, "firstName" => "John", "lastName" => "Doe" }
    merged_fields = { "firstName" => "Zach", "lastName" => "Latta" }

    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      LoopsService.stub(:find_contact, ->(email:) { [ main_contact ] }) do
        Ai::ContactMergerService.stub(:call, merged_fields) do
          LoopsService.stub(:update_contact, ->(**args) { { "success" => true, "id" => "test_id" } }) do
            job = MassUnsubscribeJob.new
            job.perform(@main_email, @alt_emails)

            # Should create individual audit logs for each field
            audits = LoopsContactChangeAudit.where(
              email_normalized: @main_email_normalized
            ).where("provenance->>'purpose' = ?", "alt_unsubscribe_merge")

            assert audits.count >= 2, "Should create at least 2 audit logs"

            firstName_audit = audits.find { |a| a.field_name == "firstName" }
            assert_not_nil firstName_audit
            assert_equal true, firstName_audit.is_self_service
            assert_equal "Zach", firstName_audit.new_loops_value
            assert_equal "alt_unsubscribe_merge", firstName_audit.provenance["purpose"]
            assert_equal @alt_emails, firstName_audit.provenance["source_emails"]
          end
        end
      end
    end
  end

  test "creates audit logs for alt unsubscribes" do
    main_contact = { "email" => @main_email }
    merged_fields = {}

    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      LoopsService.stub(:find_contact, ->(email:) { [ main_contact ] }) do
        Ai::ContactMergerService.stub(:call, merged_fields) do
          LoopsService.stub(:update_contact, ->(**args) { { "success" => true, "id" => "test_id" } }) do
            job = MassUnsubscribeJob.new
            job.perform(@main_email, @alt_emails)

            @alt_emails.each do |alt|
              alt_normalized = EmailNormalizer.normalize(alt)
              audit = LoopsContactChangeAudit.where(
                email_normalized: alt_normalized,
                field_name: "subscribed"
              ).where("provenance->>'purpose' = ?", "alt_unsubscribe_merge").last

              assert_not_nil audit, "Should create audit log for #{alt}"
              assert_equal true, audit.is_self_service
              assert_equal true, audit.former_loops_value
              assert_equal false, audit.new_loops_value
              assert_equal "alt_unsubscribe_merge", audit.provenance["purpose"]
              assert_equal @main_email, audit.provenance["merged_into"]
            end
          end
        end
      end
    end
  end

  test "sanitizes merged fields before updating main contact" do
    main_contact = { "email" => @main_email }
    merged_fields_with_sensitive = {
      "email" => "should-be-removed",
      "id" => "should-be-removed",
      "userId" => "should-be-removed",
      "unsubscribed" => false,
      "mailingLists" => { "list1" => true }, # Should be handled separately, not in profile update
      "firstName" => "Zach"
    }

    update_calls = []
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      LoopsService.stub(:find_contact, ->(email:) { [ main_contact ] }) do
        Ai::ContactMergerService.stub(:call, merged_fields_with_sensitive) do
          LoopsService.stub(:update_contact, ->(email:, **kwargs) {
            update_calls << { email: email, kwargs: kwargs.dup }
            { "success" => true, "id" => "test_id_#{update_calls.length}" }
          }) do
            job = MassUnsubscribeJob.new
            job.perform(@main_email, @alt_emails)

            # Get all main email updates
            main_updates = update_calls.select { |c| c[:email] == @main_email }

            # First update should be profile fields (without mailingLists)
            profile_update = main_updates.first
            assert_not_nil profile_update
            assert_nil profile_update[:kwargs]["email"]
            assert_nil profile_update[:kwargs]["id"]
            assert_nil profile_update[:kwargs]["userId"]
            assert_nil profile_update[:kwargs]["unsubscribed"]
            assert_nil profile_update[:kwargs]["mailingLists"], "mailingLists should be removed from profile update"
            assert_equal "Zach", profile_update[:kwargs]["firstName"]

            # Second update should be mailingLists separately
            mailing_lists_update = main_updates.find { |u| u[:kwargs].key?("mailingLists") }
            assert_not_nil mailing_lists_update, "mailingLists should be updated separately"
            assert_equal({ "list1" => true }, mailing_lists_update[:kwargs]["mailingLists"])
          end
        end
      end
    end
  end

  test "updates main contact in batches when there are more than 50 fields" do
    main_contact = { "email" => @main_email }
    # Create 60 fields to trigger batching
    merged_fields = {}
    60.times { |i| merged_fields["field#{i}"] = "value#{i}" }

    update_calls = []
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      LoopsService.stub(:find_contact, ->(email:) { [ main_contact ] }) do
        Ai::ContactMergerService.stub(:call, merged_fields) do
          LoopsService.stub(:update_contact, ->(email:, **kwargs) {
            update_calls << { email: email, kwargs: kwargs }
            { "success" => true, "id" => "test_id" }
          }) do
            job = MassUnsubscribeJob.new
            job.perform(@main_email, @alt_emails)

            # Should have multiple update calls for main email (batched)
            main_updates = update_calls.select { |c| c[:email] == @main_email }
            assert main_updates.length >= 2, "Should update in batches when >50 fields"

            # Verify total fields across all batches equals expected (minus removed fields)
            total_fields = main_updates.sum { |c| c[:kwargs].length }
            assert_equal 60, total_fields, "All fields should be updated"
          end
        end
      end
    end
  end

  test "handles partial failures gracefully" do
    main_contact = { "email" => @main_email }
    merged_fields = { "firstName" => "Zach" }

    call_count = 0
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      LoopsService.stub(:find_contact, ->(email:) { [ main_contact ] }) do
        Ai::ContactMergerService.stub(:call, merged_fields) do
          LoopsService.stub(:update_contact, ->(**args) {
            call_count += 1
            if call_count == 1
              # Main contact update succeeds
              { "success" => true, "id" => "test_id" }
            elsif call_count == 2
              # First alt unsubscribe fails
              { "success" => false }
            else
              # Second alt unsubscribe succeeds
              { "success" => true, "id" => "test_id_#{call_count}" }
            end
          }) do
            job = MassUnsubscribeJob.new
            # Should not raise error, but continue processing
            job.perform(@main_email, @alt_emails)

            # Should still create audit log for main contact
            audits = LoopsContactChangeAudit.where(
              email_normalized: @main_email_normalized
            ).where("provenance->>'purpose' = ?", "alt_unsubscribe_merge")
            assert audits.any?, "Should create audit logs for merged fields"
          end
        end
      end
    end
  end

  test "raises error if no contacts found" do
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      LoopsService.stub(:find_contact, ->(email:) { [] }) do
        job = MassUnsubscribeJob.new
        assert_raises(RuntimeError) do
          job.perform(@main_email, @alt_emails)
        end
      end
    end
  end

  test "only creates audit logs for fields that actually changed" do
    main_contact = { "email" => @main_email, "firstName" => "Zach", "lastName" => "Latta" }
    # Merged fields include some that changed and some that didn't
    merged_fields = {
      "firstName" => "Zach", # Same value - should NOT create audit log
      "lastName" => "Smith"   # Different value - SHOULD create audit log
    }

    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      LoopsService.stub(:find_contact, ->(email:) { [ main_contact ] }) do
        Ai::ContactMergerService.stub(:call, merged_fields) do
          LoopsService.stub(:update_contact, ->(**args) { { "success" => true, "id" => "test_id" } }) do
            job = MassUnsubscribeJob.new
            job.perform(@main_email, @alt_emails)

            # Should only create audit log for lastName (which changed)
            audits = LoopsContactChangeAudit.where(
              email_normalized: @main_email_normalized
            ).where("provenance->>'purpose' = ?", "alt_unsubscribe_merge")

            # Should have exactly 1 audit log (for lastName)
            assert_equal 1, audits.count, "Should only create audit log for changed field"

            lastName_audit = audits.find { |a| a.field_name == "lastName" }
            assert_not_nil lastName_audit
            assert_equal "Latta", lastName_audit.former_loops_value
            assert_equal "Smith", lastName_audit.new_loops_value

            # Should NOT have audit log for firstName (didn't change)
            firstName_audit = audits.find { |a| a.field_name == "firstName" }
            assert_nil firstName_audit, "Should not create audit log for unchanged field"
          end
        end
      end
    end
  end

  test "uses EmailNormalizer.normalize in audit logs" do
    main_contact = { "email" => @main_email, "firstName" => "John" }
    merged_fields = { "firstName" => "Zach" }

    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      LoopsService.stub(:find_contact, ->(email:) { [ main_contact ] }) do
        Ai::ContactMergerService.stub(:call, merged_fields) do
          LoopsService.stub(:update_contact, ->(**args) { { "success" => true, "id" => "test_id" } }) do
            job = MassUnsubscribeJob.new
            job.perform(@main_email, @alt_emails)

            # Verify normalized email is used
            audit = LoopsContactChangeAudit.where(
              email_normalized: @main_email_normalized
            ).where("provenance->>'purpose' = ?", "alt_unsubscribe_merge").last
            assert_not_nil audit
            assert_equal @main_email_normalized, audit.email_normalized
          end
        end
      end
    end
  end

  test "updates profile fields first, then mailingLists separately" do
    main_contact = { "email" => @main_email, "firstName" => "John" }
    merged_fields = {
      "firstName" => "Zach",
      "lastName" => "Latta",
      "mailingLists" => { "list1" => true, "list2" => true, "list3" => true }
    }

    update_calls = []
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      LoopsService.stub(:find_contact, ->(email:) { [ main_contact ] }) do
        Ai::ContactMergerService.stub(:call, merged_fields) do
          LoopsService.stub(:update_contact, ->(email:, **kwargs) {
            update_calls << { email: email, kwargs: kwargs.dup }
            { "success" => true, "id" => "test_id_#{update_calls.length}" }
          }) do
            job = MassUnsubscribeJob.new
            job.perform(@main_email, @alt_emails)

            # Get all main email updates
            main_updates = update_calls.select { |c| c[:email] == @main_email }

            # First update should be profile fields (without mailingLists)
            first_update = main_updates.first
            assert_not_nil first_update
            assert_equal "Zach", first_update[:kwargs]["firstName"]
            assert_equal "Latta", first_update[:kwargs]["lastName"]
            assert_nil first_update[:kwargs]["mailingLists"], "First update should not include mailingLists"

            # Second update should be mailingLists
            second_update = main_updates[1]
            assert_not_nil second_update
            assert_nil second_update[:kwargs]["firstName"], "Second update should only have mailingLists"
            assert_not_nil second_update[:kwargs]["mailingLists"], "Second update should include mailingLists"
            assert_equal({ "list1" => true, "list2" => true, "list3" => true }, second_update[:kwargs]["mailingLists"])
          end
        end
      end
    end
  end

  test "batches mailingLists into groups of 10" do
    main_contact = { "email" => @main_email }
    # Create 25 mailing lists to test batching
    mailing_lists = {}
    25.times { |i| mailing_lists["list#{i + 1}"] = true }

    merged_fields = {
      "firstName" => "Zach",
      "mailingLists" => mailing_lists
    }

    update_calls = []
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      LoopsService.stub(:find_contact, ->(email:) { [ main_contact ] }) do
        Ai::ContactMergerService.stub(:call, merged_fields) do
          LoopsService.stub(:update_contact, ->(email:, **kwargs) {
            update_calls << { email: email, kwargs: kwargs.dup }
            { "success" => true, "id" => "test_id_#{update_calls.length}" }
          }) do
            job = MassUnsubscribeJob.new
            job.perform(@main_email, @alt_emails)

            # Get all main email updates
            main_updates = update_calls.select { |c| c[:email] == @main_email }

            # First update should be profile fields
            assert_equal "Zach", main_updates.first[:kwargs]["firstName"]
            assert_nil main_updates.first[:kwargs]["mailingLists"]

            # Should have 3 batches for 25 lists (10, 10, 5)
            mailing_list_updates = main_updates[1..-1].select { |u| u[:kwargs].key?("mailingLists") }
            assert_equal 3, mailing_list_updates.length, "Should have 3 batches for 25 lists"

            # Verify first batch has 10 lists
            batch1_lists = mailing_list_updates[0][:kwargs]["mailingLists"]
            assert_equal 10, batch1_lists.length, "First batch should have 10 lists"
            assert_equal "list1", batch1_lists.keys.first
            assert_equal "list10", batch1_lists.keys.last

            # Verify second batch has 10 lists
            batch2_lists = mailing_list_updates[1][:kwargs]["mailingLists"]
            assert_equal 10, batch2_lists.length, "Second batch should have 10 lists"
            assert_equal "list11", batch2_lists.keys.first
            assert_equal "list20", batch2_lists.keys.last

            # Verify third batch has 5 lists
            batch3_lists = mailing_list_updates[2][:kwargs]["mailingLists"]
            assert_equal 5, batch3_lists.length, "Third batch should have 5 lists"
            assert_equal "list21", batch3_lists.keys.first
            assert_equal "list25", batch3_lists.keys.last
          end
        end
      end
    end
  end

  test "handles empty mailingLists hash gracefully" do
    main_contact = { "email" => @main_email }
    merged_fields = {
      "firstName" => "Zach",
      "mailingLists" => {}
    }

    update_calls = []
    LoopsService.stub(:send_transactional_email, ->(*args) { { "success" => true } }) do
      LoopsService.stub(:find_contact, ->(email:) { [ main_contact ] }) do
        Ai::ContactMergerService.stub(:call, merged_fields) do
          LoopsService.stub(:update_contact, ->(email:, **kwargs) {
            update_calls << { email: email, kwargs: kwargs.dup }
            { "success" => true, "id" => "test_id" }
          }) do
            job = MassUnsubscribeJob.new
            job.perform(@main_email, @alt_emails)

            # Should only have one update (profile fields)
            main_updates = update_calls.select { |c| c[:email] == @main_email }
            assert_equal 1, main_updates.length, "Should only update profile fields when mailingLists is empty"
            assert_equal "Zach", main_updates.first[:kwargs]["firstName"]
            assert_nil main_updates.first[:kwargs]["mailingLists"]
          end
        end
      end
    end
  end
end
