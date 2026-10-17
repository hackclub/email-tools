require "securerandom"

# Self-service subscription management (requires OTP auth, NOT admin auth).
#
# Lets someone verify an email and then:
# - subscribe it to Hack Club emails (creating the Loops contact if it's new)
# - resubscribe it after a past unsubscribe
# - unsubscribe it
# - choose which mailing lists it's on: every public list, plus any list it's on
#   now or was on before (even private ones), so people can get back on them
class SubscriptionsController < ApplicationController
  skip_before_action :authenticate_admin
  before_action :require_authenticated_session

  NEW_CONTACT_SOURCE = "Email Tools Self-Service".freeze
  LISTS_PER_REQUEST = 10

  def edit
    @email = current_authenticated_email
    @contact = fetch_contact(@email)
    @lists = visible_lists(@contact, EmailNormalizer.normalize(@email))
    @checked_list_ids = checked_list_ids(@contact, @lists)
    @previous_list_ids = past_list_ids(EmailNormalizer.normalize(@email)) - @checked_list_ids
  rescue => e
    Rails.logger.error("SubscriptionsController#edit error: #{e.class} - #{e.message}")
    flash[:error] = "Failed to load your subscriptions. Please try again."
    redirect_to root_path
  end

  def update
    email = current_authenticated_email
    email_normalized = EmailNormalizer.normalize(email)
    contact = fetch_contact(email)
    lists = visible_lists(contact, email_normalized)

    currently_subscribed = contact.present? && contact["subscribed"] != false
    wants_subscribed = params[:subscribed] == "1"

    # Only lists shown on the page can be changed here; ignore anything else that's submitted
    visible_ids = lists.map(&:loops_list_id)
    selected_ids = Array(params[:list_ids]).map(&:to_s) & visible_ids
    current_memberships = contact&.dig("mailingLists") || {}

    list_changes = {}
    if wants_subscribed
      visible_ids.each do |list_id|
        wanted = selected_ids.include?(list_id)
        list_changes[list_id] = wanted if wanted != (current_memberships[list_id] == true)
      end
    end

    subscribed_changed = wants_subscribed != currently_subscribed

    if !subscribed_changed && list_changes.empty?
      flash[:notice] = "No changes detected"
      redirect_to subscriptions_path
      return
    end

    # First request carries the subscription status (and initial fields for new
    # contacts); mailing lists go in batches since large payloads fail
    requests = []
    first_payload = {}
    first_payload[:subscribed] = wants_subscribed if subscribed_changed
    if contact.nil?
      first_payload[:source] = NEW_CONTACT_SOURCE
      first_payload[:userGroup] = "Hack Clubber"
    end
    list_batches = list_changes.to_a.each_slice(LISTS_PER_REQUEST).map(&:to_h)
    first_payload[:mailingLists] = list_batches.shift if list_batches.any?
    requests << first_payload
    list_batches.each { |batch| requests << { mailingLists: batch } }

    request_id = nil
    requests.each do |payload|
      response = LoopsService.update_contact(email: email, **payload)
      unless response && response["success"] == true
        raise "Loops update failed: #{response.inspect}"
      end
      request_id ||= response["id"]
    end
    request_id ||= SecureRandom.uuid

    record_changes(
      email_normalized: email_normalized,
      request_id: request_id,
      subscribed_change: subscribed_changed ? [ currently_subscribed, wants_subscribed ] : nil,
      list_changes: list_changes,
      lists: lists
    )

    flash[:notice] = success_message(contact, wants_subscribed, subscribed_changed)
    redirect_to subscriptions_path
  rescue => e
    Rails.logger.error("SubscriptionsController#update error: #{e.class} - #{e.message}")
    flash[:error] = "Failed to update your subscriptions. Please try again."
    redirect_to subscriptions_path
  end

  private

  def fetch_contact(email)
    LoopsService.find_contact(email: email).first
  end

  # Public lists, plus every list this email is on now or was ever on: current
  # Loops memberships, lists our sync added it to, and lists changed in audits
  def visible_lists(contact, email_normalized)
    known_ids = past_list_ids(email_normalized)
    (contact&.dig("mailingLists") || {}).each { |id, on| known_ids << id.to_s if on == true }

    lists = LoopsList.where(is_public: true).or(LoopsList.where(loops_list_id: known_ids)).to_a
    lists.sort_by { |l| l.name.to_s.downcase }
  end

  def past_list_ids(email_normalized)
    ids = LoopsListSubscription.where(email_normalized: email_normalized).pluck(:list_id)
    ids += LoopsContactChangeAudit
      .where(email_normalized: email_normalized)
      .where("field_name LIKE 'mailingList:%'")
      .distinct
      .pluck(:field_name)
      .map { |f| f.delete_prefix("mailingList:") }
    ids.uniq
  end

  # Lists to show as checked: current memberships, or the default list for
  # someone who isn't in Loops yet
  def checked_list_ids(contact, lists)
    list_ids = lists.map(&:loops_list_id)

    if contact.nil?
      default_id = ENV["DEFAULT_LOOPS_LIST_ID"].presence
      default_list = lists.find { |l| l.loops_list_id == default_id }
      return default_list&.is_public ? [ default_id ] : []
    end

    memberships = contact["mailingLists"] || {}
    list_ids.select { |id| memberships[id] == true }
  end

  def record_changes(email_normalized:, request_id:, subscribed_change:, list_changes:, lists:)
    provenance = { purpose: "subscription_management", initiated_by: "user" }

    if subscribed_change
      LoopsContactChangeAudit.create!(
        occurred_at: Time.current,
        email_normalized: email_normalized,
        field_name: "subscribed",
        former_loops_value: subscribed_change[0],
        new_loops_value: subscribed_change[1],
        strategy: "upsert",
        sync_source_id: nil,
        is_self_service: true,
        provenance: provenance,
        request_id: request_id
      )
    end

    list_changes.each do |list_id, subscribed|
      # Mark the list as handled for this email either way, so the Airtable sync
      # never re-adds someone who removed themselves here
      begin
        LoopsListSubscription.find_or_create_by!(email_normalized: email_normalized, list_id: list_id)
      rescue ActiveRecord::RecordNotUnique
        # Created concurrently by the sync pipeline
      end

      list = lists.find { |l| l.loops_list_id == list_id }
      LoopsContactChangeAudit.create!(
        occurred_at: Time.current,
        email_normalized: email_normalized,
        field_name: "mailingList:#{list_id}",
        former_loops_value: !subscribed,
        new_loops_value: subscribed,
        strategy: subscribed ? "subscribe" : "unsubscribe",
        sync_source_id: nil,
        is_self_service: true,
        provenance: provenance.merge(list: { id: list_id, name: list&.name, is_public: list&.is_public }),
        request_id: request_id
      )
    end
  end

  def success_message(contact, wants_subscribed, subscribed_changed)
    return "Your mailing lists have been updated." unless subscribed_changed

    if !wants_subscribed
      "You've been unsubscribed from Hack Club emails."
    elsif contact.nil?
      "You're subscribed to Hack Club emails!"
    else
      "Welcome back! You've been resubscribed to Hack Club emails."
    end
  end
end
