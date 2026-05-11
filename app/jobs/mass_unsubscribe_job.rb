require_relative "../lib/email_normalizer"
require "securerandom"

class MassUnsubscribeJob
  include Sidekiq::Worker
  sidekiq_options queue: :default, retry: 3

  def perform(main_email, alt_emails)
    # Track results for email notification
    results = {
      unsubscribed: [],
      already_unsubscribed: [],
      errors: [],
      profile_changes: []
    }

    begin
      all_emails = [ main_email ] + alt_emails

      # 1. Fetch contact data for all emails
      contacts_data = all_emails.map do |email|
        contacts = LoopsService.find_contact(email: email)
        contacts.first # Returns the contact hash or nil
      end.compact

      if contacts_data.empty?
        error_msg = "No contacts found for emails: #{all_emails.join(', ')}"
        Rails.logger.error("MassUnsubscribeJob: #{error_msg}")
        results[:errors] << error_msg
        send_results_email(main_email, results)
        raise "No contacts found"
      end

      # Get current profile to compare values
      current_profile = contacts_data.find { |c| c["email"] == main_email } || {}

      # 2. Use AI to merge contact fields
      merged_fields = Ai::ContactMergerService.call(contacts: contacts_data, main_email: main_email)

      # Sanitize merged fields: remove fields that shouldn't be updated
      merged_fields.delete("email")
      merged_fields.delete("id")
      merged_fields.delete("userId")
      merged_fields.delete("subscribed") # We don't want to accidentally change subscription status of the main account
      merged_fields.delete("unsubscribed") # Also remove unsubscribed field

      # Extract mailingLists before removing it - we'll handle it separately
      # mailingLists can be very large and cause API errors, so we batch it
      mailing_lists = merged_fields.delete("mailingLists")
      mailing_lists = {} unless mailing_lists.is_a?(Hash)

      # Track profile field changes (firstName, lastName, birthday, genderSelfReported, address fields)
      profile_fields_to_track = [ "firstName", "lastName", "birthday", "genderSelfReported",
                                  "addressLine1", "addressLine2", "addressCity", "addressState",
                                  "addressZipCode", "addressCountry" ]

      # 3. Update main contact profile fields first (without mailingLists)
      # Update in batches if there are too many fields to avoid API limits
      if merged_fields.length > 50
        Rails.logger.info("MassUnsubscribeJob: Updating #{merged_fields.length} profile fields in batches")
        # Update in batches of 50 fields
        batch_responses = []
        merged_fields.each_slice(50).with_index do |batch, index|
          batch_hash = batch.to_h
          batch_response = LoopsService.update_contact(email: main_email, **batch_hash)

          unless batch_response && batch_response["success"] == true
            error_msg = "Failed to update main contact #{main_email} profile fields in batch #{index + 1}"
            Rails.logger.error("MassUnsubscribeJob: #{error_msg}")
            results[:errors] << error_msg
            # Continue with remaining batches, but track the failure
            next
          end

          batch_responses << batch_response
        end

        # Check if any batch succeeded
        if batch_responses.empty?
          error_msg = "All profile field batch updates failed for main contact #{main_email}"
          Rails.logger.error("MassUnsubscribeJob: #{error_msg}")
          results[:errors] << error_msg
          send_results_email(main_email, results)
          raise "Failed to update main contact"
        end

        # Use the last successful response (or generate an ID if needed)
        update_response = batch_responses.last
        # Ensure we have an ID for audit logs
        update_response["id"] ||= SecureRandom.uuid
      else
        # Only update if there are profile fields to update
        if merged_fields.any?
          update_response = LoopsService.update_contact(email: main_email, **merged_fields)
        else
          # No profile fields to update, create a dummy response for audit logs
          update_response = { "success" => true, "id" => SecureRandom.uuid }
        end
      end

      unless update_response && update_response["success"] == true
        error_msg = "Failed to update main contact #{main_email} profile fields"
        Rails.logger.error("MassUnsubscribeJob: #{error_msg}")
        results[:errors] << error_msg
        send_results_email(main_email, results)
        raise "Failed to update main contact"
      end

      # 4. Update mailingLists separately in batches of 10
      if mailing_lists.any?
        # Filter to only subscribed lists (value is true)
        subscribed_lists = mailing_lists.select { |_id, subscribed| subscribed == true }

        if subscribed_lists.any?
          Rails.logger.info("MassUnsubscribeJob: Updating #{subscribed_lists.length} mailing lists in batches of 10")

          # Convert hash to array of [key, value] pairs, batch into groups of 10, then convert back to hash
          subscribed_lists.to_a.each_slice(10).with_index do |batch, index|
            # Convert array of [key, value] pairs back to hash
            batch_hash = { "mailingLists" => batch.to_h }
            batch_response = LoopsService.update_contact(email: main_email, **batch_hash)

            unless batch_response && batch_response["success"] == true
              error_msg = "Failed to update main contact #{main_email} mailing lists in batch #{index + 1}"
              Rails.logger.error("MassUnsubscribeJob: #{error_msg}")
              results[:errors] << error_msg
              # Continue with remaining batches, but track the failure
              next
            end

            Rails.logger.info("MassUnsubscribeJob: Successfully updated mailing lists batch #{index + 1} (#{batch.length} lists)")
          end
        end
      end

      main_email_normalized = EmailNormalizer.normalize(main_email)
      request_id = update_response["id"] || SecureRandom.uuid

      # Create individual audit log entries for each field that was merged
      # This matches the pattern used by profile updates - one entry per field
      # Only create audit logs for fields that actually changed
      merged_fields.each do |field_name, new_value|
        former_value = current_profile[field_name] if current_profile.is_a?(Hash)

        # Get baseline for former value if not in current profile
        baseline = LoopsFieldBaseline.find_or_create_baseline(
          email_normalized: main_email_normalized,
          field_name: field_name
        )
        former_loops_value = baseline.last_sent_value || former_value

        # Normalize values for comparison (handle nil, empty strings, arrays, hashes)
        former_normalized = case former_loops_value
        when nil
            nil
        when String
            former_loops_value.strip
        when Array, Hash
            former_loops_value.to_json
        else
            former_loops_value
        end

        new_normalized = case new_value
        when nil
            nil
        when String
            new_value.strip
        when Array, Hash
            new_value.to_json
        else
            new_value
        end

        # Skip creating audit log if values are the same
        next if former_normalized == new_normalized

        # Track profile field changes
        if profile_fields_to_track.include?(field_name)
          results[:profile_changes] << {
            field: field_name,
            former_value: former_loops_value,
            new_value: new_value
          }
        end

        # Create audit log entry for this field (only if it changed)
        LoopsContactChangeAudit.create!(
          occurred_at: Time.current,
          email_normalized: main_email_normalized,
          field_name: field_name,
          former_loops_value: former_loops_value,
          new_loops_value: new_value,
          strategy: "upsert",
          sync_source_id: nil,
          is_self_service: true,
          provenance: {
            purpose: "alt_unsubscribe_merge",
            source_emails: alt_emails,
            initiated_by: "user"
          },
          request_id: request_id
        )

        # Update baseline
        baseline.update_sent_value(value: new_value, expires_in_days: 90)
      end

      # 4. Unsubscribe alt emails and create audit logs
      alt_emails.each do |alt|
        # Check if already unsubscribed before attempting
        alt_contact = contacts_data.find { |c| c["email"] == alt }
        if alt_contact && alt_contact["subscribed"] == false
          results[:already_unsubscribed] << alt
          next
        end

        unsubscribe_response = LoopsService.update_contact(email: alt, subscribed: false)

        unless unsubscribe_response && unsubscribe_response["success"] == true
          error_msg = "Failed to unsubscribe #{alt}"
          Rails.logger.error("MassUnsubscribeJob: #{error_msg}")
          results[:errors] << error_msg
          # Continue with other alts even if one fails
          next
        end

        results[:unsubscribed] << alt

        alt_email_normalized = EmailNormalizer.normalize(alt)
        alt_request_id = unsubscribe_response["id"] || SecureRandom.uuid

        LoopsContactChangeAudit.create!(
          occurred_at: Time.current,
          email_normalized: alt_email_normalized,
          field_name: "subscribed",
          former_loops_value: true,
          new_loops_value: false,
          strategy: "upsert",
          sync_source_id: nil,
          is_self_service: true,
          provenance: {
            purpose: "alt_unsubscribe_merge",
            merged_into: main_email,
            initiated_by: "user"
          },
          request_id: alt_request_id
        )
      end

      # Send results email
      send_results_email(main_email, results)
    rescue => e
      error_msg = "Error processing unsubscribe for #{main_email}: #{e.class} - #{e.message}"
      Rails.logger.error("MassUnsubscribeJob: #{error_msg}")
      Rails.logger.error("MassUnsubscribeJob: Backtrace: #{e.backtrace.first(10).join("\n")}")
      results[:errors] << error_msg
      send_results_email(main_email, results)
      raise # Re-raise for Sidekiq retry
    end
  end

  private

  def send_results_email(main_email, results)
    transactional_id = ENV.fetch("LOOPS_ALT_UNSUBSCRIBE_RESULTS_TRANSACTIONAL_ID")

    # Build email body
    body_parts = []

    # Unsubscribed emails
    if results[:unsubscribed].any?
      body_parts << "Successfully unsubscribed #{results[:unsubscribed].length} alternate email(s):"
      results[:unsubscribed].each do |email|
        body_parts << "  • #{email}"
      end
      body_parts << ""
    end

    # Already unsubscribed emails
    if results[:already_unsubscribed].any?
      body_parts << "The following #{results[:already_unsubscribed].length} email(s) were already unsubscribed:"
      results[:already_unsubscribed].each do |email|
        body_parts << "  • #{email}"
      end
      body_parts << ""
    end

    # Profile changes
    if results[:profile_changes].any?
      body_parts << "Profile information was updated:"
      results[:profile_changes].each do |change|
        field_display = change[:field].gsub(/([A-Z])/, ' \1').strip.capitalize
        former_display = format_field_value(change[:former_value])
        new_display = format_field_value(change[:new_value])
        body_parts << "  • #{field_display}: #{former_display} → #{new_display}"
      end
      body_parts << ""
    end

    # Errors
    if results[:errors].any?
      body_parts << "Errors encountered:"
      results[:errors].each do |error|
        body_parts << "  • #{error}"
      end
      body_parts << ""
    end

    # If nothing happened
    if results[:unsubscribed].empty? && results[:already_unsubscribed].empty? &&
       results[:profile_changes].empty? && results[:errors].empty?
      body_parts << "No changes were made to your account."
    end

    body = body_parts.join("\n")

    begin
      Rails.logger.info("MassUnsubscribeJob: Attempting to send results email to #{main_email}")
      Rails.logger.info("MassUnsubscribeJob: Transactional ID: #{transactional_id}")
      Rails.logger.info("MassUnsubscribeJob: Email body length: #{body.length} characters")

      response = LoopsService.send_transactional_email(
        email: main_email,
        transactional_id: transactional_id,
        data_variables: { body: body }
      )

      Rails.logger.info("MassUnsubscribeJob: Sent results email to #{main_email}, response: #{response.inspect}")
      logger.info("MassUnsubscribeJob: Sent results email to #{main_email}") if respond_to?(:logger)
    rescue => e
      error_msg = "MassUnsubscribeJob: Failed to send results email to #{main_email}: #{e.class} - #{e.message}"
      Rails.logger.error(error_msg)
      Rails.logger.error("MassUnsubscribeJob: Backtrace: #{e.backtrace.first(5).join("\n")}")
      logger.error(error_msg) if respond_to?(:logger)
      # Don't raise - email failure shouldn't fail the job
    end
  end

  def format_field_value(value)
    return "empty" if value.nil? || value == ""
    return value.to_s if value.is_a?(String) || value.is_a?(Numeric)
    return value.to_json if value.is_a?(Array) || value.is_a?(Hash)
    value.to_s
  end
end
