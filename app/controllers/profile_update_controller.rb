require "securerandom"

class ProfileUpdateController < ApplicationController
  skip_before_action :authenticate_admin
  before_action :require_authenticated_session

  PROFILE_FIELDS = %w[firstName lastName genderSelfReported birthdayYear birthdayMonth birthdayDay addressLine1 addressLine2 addressCity addressState addressZipCode addressCountry].freeze
  
  REQUIRED_ADDRESS_FIELDS = %w[addressLine1 addressCity addressState addressZipCode addressCountry].freeze

  def edit
    @email = current_authenticated_email
    @profile = fetch_current_profile(@email)
  rescue => e
    Rails.logger.error("ProfileUpdateController#edit error: #{e.class} - #{e.message}")
    flash[:error] = "Failed to load profile. Please try again."
    redirect_to root_path
  end

  def update
    email = current_authenticated_email
    profile_params = params.permit(*PROFILE_FIELDS)

    # Recombine birthday fields if any are present
    birthday_fields = {
      year: profile_params["birthdayYear"],
      month: profile_params["birthdayMonth"],
      day: profile_params["birthdayDay"]
    }
    
    # Get current profile to compare what changed
    current_profile = fetch_current_profile(email)
    
    # Check if birthday fields have changed from current values
    current_birthday = {
      year: current_profile["birthdayYear"],
      month: current_profile["birthdayMonth"],
      day: current_profile["birthdayDay"]
    }
    
    # Only check if birthday changed if at least one field is present
    birthday_fields_present = birthday_fields.values.any?(&:present?)
    birthday_changed = false
    
    if birthday_fields_present
      birthday_changed = birthday_fields[:year] != current_birthday[:year] ||
                         birthday_fields[:month] != current_birthday[:month] ||
                         birthday_fields[:day] != current_birthday[:day]
    end
    
    # If birthday changed, combine them
    if birthday_changed
      # Check if all required birthday fields are present
      if birthday_fields.values.all?(&:present?)
        begin
          # Combine into ISO8601 format: YYYY-MM-DDTHH:MM:SS.000Z
          year = birthday_fields[:year].to_i
          month = birthday_fields[:month].to_i
          day = birthday_fields[:day].to_i
          
          # Validate date
          date = Date.new(year, month, day)
          profile_params["birthday"] = date.strftime("%Y-%m-%dT00:00:00.000Z")
        rescue ArgumentError => e
          flash[:error] = "Invalid date: #{e.message}"
          redirect_to profile_edit_path
          return
        end
      else
        flash[:error] = "If editing birthday, all fields (year, month, day) are required"
        redirect_to profile_edit_path
        return
      end
    end
    
    # Remove birthday component fields from params (we've combined them into birthday)
    profile_params = profile_params.except("birthdayYear", "birthdayMonth", "birthdayDay")

    # Only include fields that have changed from current values AND have non-blank values
    # This ensures we don't send nil/empty values that would overwrite existing data
    # (upsert behavior: only update fields that are explicitly provided with values)
    fields_to_update = {}
    
    profile_params.each do |key, new_value|
      current_value = current_profile[key]
      
      # Normalize values for comparison (handle nil/empty strings)
      current_normalized = (current_value || "").to_s.strip
      new_normalized = (new_value || "").to_s.strip
      
      # Skip if values are the same
      next if new_normalized == current_normalized
      
      # Only include fields with non-blank values
      # This preserves existing values when form can't match them (e.g., nonstandard genders)
      # and follows upsert principle: only update fields explicitly set
      next unless new_value.present?
      
      fields_to_update[key] = new_value
    end
    
    # Handle addressLine2: if any REQUIRED address field is being edited, include it even if blank
    required_address_fields_being_edited = fields_to_update.keys.any? { |k| REQUIRED_ADDRESS_FIELDS.include?(k) }
    if required_address_fields_being_edited && profile_params.key?("addressLine2")
      # Check if addressLine2 changed
      current_line2 = (current_profile["addressLine2"] || "").to_s.strip
      new_line2 = (profile_params["addressLine2"] || "").to_s.strip
      if new_line2 != current_line2
        fields_to_update["addressLine2"] = profile_params["addressLine2"].presence
      end
    end

    if fields_to_update.empty?
      flash[:notice] = "No changes detected"
      redirect_to profile_edit_path
      return
    end

    # Validate address fields: if any REQUIRED address field is edited, all required ones must be present
    # Note: addressLine2 can be edited independently without requiring other fields
    required_address_fields_edited = fields_to_update.keys.any? { |k| REQUIRED_ADDRESS_FIELDS.include?(k) }
    if required_address_fields_edited
      missing_required = REQUIRED_ADDRESS_FIELDS.reject { |field| fields_to_update.key?(field) || current_profile[field].present? }
      if missing_required.any?
        flash[:error] = "If editing address, the following fields are required: #{missing_required.join(', ')}"
        redirect_to profile_edit_path
        return
      end
    end

    begin
      # Update via LoopsService
      response = LoopsService.update_contact(email: email, **fields_to_update)

      unless response && response["success"] == true
        flash[:error] = "Failed to update profile"
        redirect_to profile_edit_path
        return
      end

      # Create audit log entries for each updated field
      request_id = response["id"] || SecureRandom.uuid

      fields_to_update.each do |field_name, new_value|
        former_value = current_profile[field_name] if current_profile.is_a?(Hash)

        # Get baseline for former value if not in current profile
        baseline = LoopsFieldBaseline.find_or_create_baseline(
          email_normalized: email,
          field_name: field_name
        )
        former_loops_value = baseline.last_sent_value || former_value

        # Create audit log entry
        LoopsContactChangeAudit.create!(
          occurred_at: Time.current,
          email_normalized: email,
          field_name: field_name,
          former_loops_value: former_loops_value,
          new_loops_value: new_value,
          strategy: "upsert",
          sync_source_id: nil,
          is_self_service: true,
          provenance: {
            purpose: "profile_update",
            initiated_by: "user"
          },
          request_id: request_id
        )

        # Update baseline
        baseline.update_sent_value(value: new_value, expires_in_days: 90)
      end

      flash[:notice] = "Profile updated successfully!"
      redirect_to profile_edit_path
    rescue => e
      Rails.logger.error("ProfileUpdateController#update error: #{e.class} - #{e.message}")
      flash[:error] = "Failed to update profile. Please try again."
      redirect_to profile_edit_path
    end
  end

  private

  def fetch_current_profile(email)
    contacts = LoopsService.find_contact(email: email)
    return {} if contacts.empty?

    contact = contacts.first
    
    # Parse birthday from ISO8601 string to extract year, month, day for placeholders
    birthday_year = nil
    birthday_month = nil
    birthday_day = nil
    
    if contact["birthday"].present?
      begin
        # Parse ISO8601 string and extract date components
        parsed_date = Time.parse(contact["birthday"])
        birthday_year = parsed_date.year.to_s
        birthday_month = parsed_date.month.to_s  # No padding for placeholder
        birthday_day = parsed_date.day.to_s  # No padding for placeholder
      rescue => e
        Rails.logger.warn("Failed to parse birthday: #{contact['birthday']} - #{e.message}")
      end
    end
    
    {
      "firstName" => contact["firstName"],
      "lastName" => contact["lastName"],
      "genderSelfReported" => contact["genderSelfReported"],
      "birthdayYear" => birthday_year,
      "birthdayMonth" => birthday_month,
      "birthdayDay" => birthday_day,
      "addressLine1" => contact["addressLine1"],
      "addressLine2" => contact["addressLine2"],
      "addressCity" => contact["addressCity"],
      "addressState" => contact["addressState"],
      "addressZipCode" => contact["addressZipCode"],
      "addressCountry" => contact["addressCountry"]
    }
  end
end

