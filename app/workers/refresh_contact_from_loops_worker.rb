require_relative "../lib/email_normalizer"

class RefreshContactFromLoopsWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default

  # Refresh a contact's loops fields and mailing lists from Loops API
  #
  # This worker:
  # - Fetches the contact from Loops API by email
  # - Updates/creates LoopsFieldBaseline records with current values
  # - Updates/creates LoopsListSubscription records with current mailing list memberships
  # - If contact doesn't exist in Loops, logs a warning and returns
  #
  # @param email [String] The email address to refresh (will be normalized)
  def perform(email)
    email_normalized = nil
    begin
      email_normalized = EmailNormalizer.normalize(email)
      unless email_normalized
        Rails.logger.error("RefreshContactFromLoopsWorker: Invalid email: #{email}")
        return
      end

      # Fetch contact from Loops API
      contacts = LoopsService.find_contact(email: email_normalized)

      if contacts.empty?
        Rails.logger.warn("RefreshContactFromLoopsWorker: Contact not found in Loops: #{email_normalized}")
        return
      end

      # Contact exists - take the first one (find_contact returns array)
      contact_hash = contacts.first

      # Refresh baselines from the contact's current properties
      seeded_fields = LoopsFieldBaseline.seed_from_loops_response!(email_normalized, contact_hash)
      Rails.logger.info("RefreshContactFromLoopsWorker: Refreshed #{seeded_fields} field(s) for #{email_normalized}")

      # Refresh list subscriptions
      seeded_subscriptions = LoopsFieldBaseline.seed_list_subscriptions_from_loops_response!(email_normalized, contact_hash)
      Rails.logger.info("RefreshContactFromLoopsWorker: Refreshed #{seeded_subscriptions} mailing list subscription(s) for #{email_normalized}")
    rescue LoopsService::ApiError => e
      email_for_logging = email_normalized || email
      Rails.logger.error("RefreshContactFromLoopsWorker: API error for #{email_for_logging}: #{e.class} - #{e.message}")
      raise
    rescue => e
      email_for_logging = email_normalized || email
      Rails.logger.error("RefreshContactFromLoopsWorker: Unexpected error for #{email_for_logging}: #{e.class} - #{e.message}")
      Rails.logger.error("RefreshContactFromLoopsWorker: Backtrace: #{e.backtrace.first(5).join("\n")}")
      raise
    end
  end
end
