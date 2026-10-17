# Self-service subscription management (requires OTP auth, NOT admin auth).
#
# Lets someone verify an email and then:
# - subscribe it to Hack Club emails (creating the Loops contact if it's new)
# - resubscribe it after a past unsubscribe
# - unsubscribe it
# - choose which mailing lists it's on: every public list, plus any list it's on
#   now or was on before (even private ones), so people can get back on them
#
# Changes go through the Loops outbox (LoopsOutboxEnvelope -> LoopsDispatchWorker)
# like every other Loops write, so they get the same per-email locking, rate
# limiting, baselines and LoopsContactChangeAudit rows (is_self_service = true).
class SubscriptionsController < ApplicationController
  skip_before_action :authenticate_admin
  before_action :require_authenticated_session

  NEW_CONTACT_SOURCE = "Email Tools Self-Service".freeze

  def edit
    @email = current_authenticated_email
    email_normalized = EmailNormalizer.normalize(@email)
    @contact = fetch_contact(@email)
    @pending = pending_envelopes(email_normalized)
    @lists = visible_lists(@contact, email_normalized)
    @subscribed = effective_subscribed(@contact, @pending)
    @checked_list_ids = checked_list_ids(@contact, @lists, @pending)
    @previous_list_ids = past_list_ids(email_normalized) - @checked_list_ids
    @change_log = change_log(email_normalized)
  rescue => e
    Rails.logger.error("SubscriptionsController#edit error: #{e.class} - #{e.message}")
    flash[:error] = "Failed to load your subscriptions. Please try again."
    redirect_to root_path
  end

  # Queues the change in the Loops outbox, the same pipeline the Airtable sync
  # uses. LoopsDispatchWorker sends it and writes the audit log once Loops
  # confirms; the page shows it as pending until then.
  def update
    email = current_authenticated_email
    email_normalized = EmailNormalizer.normalize(email)
    contact = fetch_contact(email)
    pending = pending_envelopes(email_normalized)
    lists = visible_lists(contact, email_normalized)

    currently_subscribed = effective_subscribed(contact, pending)
    wants_subscribed = params[:subscribed] == "1"

    # Only lists shown on the page can be changed here; ignore anything else that's submitted
    visible_ids = lists.map(&:loops_list_id)
    selected_ids = Array(params[:list_ids]).map(&:to_s) & visible_ids
    new_contact = contact.nil? && pending.empty?
    current_ids = new_contact ? [] : checked_list_ids(contact, lists, pending)

    list_changes = {}
    if wants_subscribed
      visible_ids.each do |list_id|
        wanted = selected_ids.include?(list_id)
        list_changes[list_id] = wanted if wanted != current_ids.include?(list_id)
      end
    end

    subscribed_changed = new_contact ? wants_subscribed : wants_subscribed != currently_subscribed

    if !subscribed_changed && list_changes.empty?
      flash[:notice] = "No changes detected"
      redirect_to subscriptions_path
      return
    end

    now = Time.current.iso8601
    payload = {}
    payload["subscribed"] = { value: wants_subscribed, strategy: :override, modified_at: now } if subscribed_changed
    payload["mailingLists"] = { value: list_changes, strategy: :override, modified_at: now } if list_changes.any?
    if contact.nil?
      payload["source"] = { value: NEW_CONTACT_SOURCE, strategy: :upsert, modified_at: now }
      payload["userGroup"] = { value: "Hack Clubber", strategy: :upsert, modified_at: now }
    end

    LoopsOutboxEnvelope.create!(
      email_normalized: email_normalized,
      payload: payload,
      provenance: {
        sync_source_type: LoopsOutboxEnvelope::SELF_SERVICE_SOURCE_TYPE,
        purpose: "subscription_management",
        initiated_by: "user",
        page: "subscriptions",
        authenticated_email: email,
        observed: {
          contact_existed: contact.present?,
          subscribed: new_contact ? nil : currently_subscribed,
          mailing_lists: visible_ids.index_with { |id| current_ids.include?(id) }
        },
        request: {
          ip: request.remote_ip,
          user_agent: request.user_agent.to_s.first(500),
          requested_at: now
        }
      },
      status: :queued
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

  # Self-service changes still waiting for LoopsDispatchWorker, oldest first
  def pending_envelopes(email_normalized)
    LoopsOutboxEnvelope.queued.self_service.for_email(email_normalized).order(:created_at).to_a
  end

  # Subscribed state as it will be once pending changes are sent
  def effective_subscribed(contact, pending)
    subscribed = contact.present? && contact["subscribed"] != false
    pending.each do |envelope|
      subscribed = envelope.payload.dig("subscribed", "value") == true if envelope.payload.key?("subscribed")
    end
    subscribed
  end

  # Lists to show as checked: current memberships with pending changes applied,
  # or the default list for someone who isn't in Loops yet
  def checked_list_ids(contact, lists, pending)
    list_ids = lists.map(&:loops_list_id)

    if contact.nil? && pending.empty?
      default_id = ENV["DEFAULT_LOOPS_LIST_ID"].presence
      default_list = lists.find { |l| l.loops_list_id == default_id }
      return default_list&.is_public ? [ default_id ] : []
    end

    memberships = (contact&.dig("mailingLists") || {}).transform_values { |on| on == true }
    pending.each do |envelope|
      memberships.merge!(envelope.payload.dig("mailingLists", "value") || {})
    end
    list_ids.select { |id| memberships[id] == true }
  end

  CHANGE_LOG_LIMIT = 25

  # Recent changes to this email: pending and failed self-service requests, plus
  # every audited change (from this page or from Hack Club's syncs)
  def change_log(email_normalized)
    entries = LoopsOutboxEnvelope.self_service.for_email(email_normalized)
      .where(status: [ :queued, :failed ])
      .order(created_at: :desc).limit(CHANGE_LOG_LIMIT)
      .map { |envelope| { at: envelope.created_at, status: envelope.status, text: describe_envelope(envelope), self_service: true } }

    LoopsContactChangeAudit.for_email(email_normalized)
      .where("field_name = 'subscribed' OR field_name LIKE 'mailingList:%'")
      .order(occurred_at: :desc).limit(CHANGE_LOG_LIMIT)
      .each { |audit| entries << { at: audit.occurred_at, status: "done", text: describe_audit(audit), self_service: audit.is_self_service } }

    entries.sort_by { |e| -e[:at].to_f }.first(CHANGE_LOG_LIMIT)
  end

  def describe_envelope(envelope)
    parts = []
    if envelope.payload.key?("subscribed")
      parts << (envelope.payload.dig("subscribed", "value") == true ? "Subscribe to Hack Club emails" : "Unsubscribe from Hack Club emails")
    end
    names = LoopsList.where(loops_list_id: (envelope.payload.dig("mailingLists", "value") || {}).keys).pluck(:loops_list_id, :name).to_h
    (envelope.payload.dig("mailingLists", "value") || {}).each do |list_id, on|
      parts << "#{on == true ? "Join" : "Leave"} #{names[list_id] || "a mailing list"}"
    end
    parts.join(", ")
  end

  def describe_audit(audit)
    if audit.field_name == "subscribed"
      audit.new_loops_value == true ? "Subscribed to Hack Club emails" : "Unsubscribed from Hack Club emails"
    else
      name = audit.provenance&.dig("list", "name") || LoopsList.find_by(loops_list_id: audit.field_name.delete_prefix("mailingList:"))&.name || "a mailing list"
      audit.new_loops_value == true ? "Joined #{name}" : "Left #{name}"
    end
  end

  def success_message(contact, wants_subscribed, subscribed_changed)
    message = if !subscribed_changed
      "Your mailing list changes are saved."
    elsif !wants_subscribed
      "You're being unsubscribed from Hack Club emails."
    elsif contact.nil?
      "You're being subscribed to Hack Club emails!"
    else
      "Welcome back! You're being resubscribed to Hack Club emails."
    end
    "#{message} It takes effect within a minute."
  end
end
