require "test_helper"

class SubscriptionsControllerTest < ActionDispatch::IntegrationTest
  def setup
    skip "Redis not available" unless REDIS_FOR_RATE_LIMITING.ping

    @email = "subs-test@example.com"
    @email_normalized = EmailNormalizer.normalize(@email)

    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{@email_normalized}")
    cleanup

    @news = LoopsList.create!(loops_list_id: "list_news", name: "Newsletter", description: "Monthly news", is_public: true)
    @events = LoopsList.create!(loops_list_id: "list_events", name: "Events", is_public: true)
    @private = LoopsList.create!(loops_list_id: "list_private", name: "Internal", is_public: false)

    @original_transactional_id = ENV["LOOPS_OTP_TRANSACTIONAL_ID"]
    ENV["LOOPS_OTP_TRANSACTIONAL_ID"] = "test_transactional_id"
    @original_default_list = ENV["DEFAULT_LOOPS_LIST_ID"]
    ENV.delete("DEFAULT_LOOPS_LIST_ID")
  end

  def teardown
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{@email_normalized}")
    cleanup
    LoopsList.where(loops_list_id: %w[list_news list_events list_private]).delete_all
    ENV["LOOPS_OTP_TRANSACTIONAL_ID"] = @original_transactional_id
    ENV["DEFAULT_LOOPS_LIST_ID"] = @original_default_list
  end

  def cleanup
    OtpVerification.where(email_normalized: @email_normalized).delete_all
    AuthenticatedSession.where(email_normalized: @email_normalized).delete_all
    LoopsContactChangeAudit.where(email_normalized: @email_normalized).delete_all
    LoopsListSubscription.where(email_normalized: @email_normalized).delete_all
    LoopsOutboxEnvelope.where(email_normalized: @email_normalized).delete_all
    LoopsFieldBaseline.where(email_normalized: @email_normalized).delete_all
  end

  def with_singleton_method_stub(object, method_name, replacement)
    original = object.method(method_name)
    object.define_singleton_method(method_name) do |*args, **kwargs, &block|
      replacement.respond_to?(:call) ? replacement.call(*args, **kwargs, &block) : replacement
    end
    yield
  ensure
    object.define_singleton_method(method_name, original)
  end

  def authenticate_user
    code = AuthenticationService.generate_otp(@email)
    with_singleton_method_stub(LoopsService, :send_transactional_email, ->(*args, **kwargs) { { "success" => true } }) do
      with_singleton_method_stub(AuthenticationService, :generate_otp, ->(email) { code }) do
        post auth_otp_request_path, params: { email: @email }
      end
    end
    post auth_otp_verify_path, params: { code: code }
    follow_redirect! if response.redirect?
  end

  # Stubs Loops: find_contact returns `contact` (nil = not in Loops), update_contact is captured
  def with_loops(contact)
    captured = []
    find = ->(**args) { contact ? [ contact ] : [] }
    update = ->(email:, **payload) { captured << { email: email, payload: payload }; { "success" => true, "id" => "req_1" } }
    with_singleton_method_stub(LoopsService, :find_contact, find) do
      with_singleton_method_stub(LoopsService, :update_contact, update) do
        yield captured
      end
    end
  end

  # Runs the outbox dispatcher for this email, as LoopsDispatchWorker does every 10s
  def dispatch!
    LoopsDispatchWorker.new.send(:process_email, @email_normalized)
  end

  def last_envelope
    LoopsOutboxEnvelope.where(email_normalized: @email_normalized).order(:created_at).last
  end

  test "edit requires authentication and remembers destination" do
    get subscriptions_path
    assert_redirected_to auth_otp_request_path
    follow_redirect!
    assert_match(/Manage Subscriptions/, response.body)
  end

  test "update requires authentication" do
    patch subscriptions_path, params: { subscribed: "1" }
    assert_redirected_to auth_otp_request_path
  end

  test "edit shows public lists and private lists the person is on, with current memberships" do
    authenticate_user
    contact = { "email" => @email, "subscribed" => true, "mailingLists" => { "list_news" => true, "list_private" => true } }

    with_loops(contact) do
      get subscriptions_path
      assert_response :success
      assert_match(/is subscribed to Hack Club emails/, response.body)
      assert_select "nav.breadcrumb a[href=?]", root_path
      assert_select "input#list_list_news[checked]"
      assert_select "input#list_list_events:not([checked])"
      assert_select "input#list_list_private[checked]"
      assert_select "input[type=submit][value=Save]"
    end
  end

  test "edit hides private lists the person was never on" do
    authenticate_user
    with_loops({ "email" => @email, "subscribed" => true, "mailingLists" => { "list_news" => true } }) do
      get subscriptions_path
      assert_select "input#list_list_private", count: 0
    end
  end

  test "edit shows lists the person was previously on, unchecked" do
    authenticate_user
    LoopsListSubscription.create!(email_normalized: @email_normalized, list_id: "list_private")
    LoopsContactChangeAudit.create!(occurred_at: Time.current, email_normalized: @email_normalized,
      field_name: "mailingList:list_events", former_loops_value: true, new_loops_value: false, strategy: "unsubscribe", is_self_service: true)

    with_loops({ "email" => @email, "subscribed" => false, "mailingLists" => {} }) do
      get subscriptions_path
      assert_select "input#list_list_private:not([checked])"
      assert_select "input#list_list_events:not([checked])"
      assert_equal 2, response.body.scan("You were on this list before.").size
    end
  end

  test "can rejoin a private list the person was previously on" do
    authenticate_user
    # The sync's opt-out marker must not stop an explicit rejoin
    LoopsListSubscription.create!(email_normalized: @email_normalized, list_id: "list_private")

    with_loops({ "email" => @email, "subscribed" => false, "mailingLists" => {} }) do |captured|
      patch subscriptions_path, params: { subscribed: "1", list_ids: [ "list_private" ] }
      assert_match(/resubscribed/, flash[:notice])
      assert_empty captured, "page must queue, not call Loops directly"

      dispatch!
      assert_equal({ subscribed: true, mailingLists: { "list_private" => true } }, captured.first[:payload])
      audit = LoopsContactChangeAudit.find_by(email_normalized: @email_normalized, field_name: "mailingList:list_private")
      assert_equal "subscribe", audit.strategy
      assert audit.is_self_service
    end
  end

  test "unsubscribed contact sees resubscribe option" do
    authenticate_user
    with_loops({ "email" => @email, "subscribed" => false, "mailingLists" => {} }) do
      get subscriptions_path
      assert_match(/is unsubscribed from Hack Club emails/, response.body)
      assert_select "input[type=submit][value=?]", "Save & Resubscribe"
    end
  end

  test "resubscribe is queued in the outbox, then sent and audited by the dispatcher" do
    authenticate_user
    with_loops({ "email" => @email, "subscribed" => false, "mailingLists" => { "list_news" => true } }) do |captured|
      patch subscriptions_path, params: { subscribed: "1", list_ids: [ "list_news" ] }

      assert_redirected_to subscriptions_path
      assert_match(/resubscribed/, flash[:notice])
      assert_empty captured
      assert_equal 0, LoopsContactChangeAudit.where(email_normalized: @email_normalized).count

      envelope = last_envelope
      assert envelope.queued?
      assert envelope.self_service?
      assert_nil envelope.sync_source_id
      assert_equal true, envelope.payload.dig("subscribed", "value")
      assert_equal "subscription_management", envelope.provenance["purpose"]
      assert_equal @email, envelope.provenance["authenticated_email"]
      assert_equal false, envelope.provenance.dig("observed", "subscribed")
      assert envelope.provenance.dig("request", "ip").present?

      dispatch!
      assert_equal [ { email: @email_normalized, payload: { subscribed: true } } ], captured
      assert envelope.reload.sent?

      audit = LoopsContactChangeAudit.find_by(email_normalized: @email_normalized, field_name: "subscribed")
      assert audit.is_self_service
      assert_nil audit.sync_source_id
      assert_equal false, audit.former_loops_value
      assert_equal true, audit.new_loops_value
      assert_equal "req_1", audit.request_id
      assert_equal envelope.id, audit.provenance["outbox_envelope_id"]
      assert_equal "subscription_management", audit.provenance["purpose"]
      assert_equal true, LoopsFieldBaseline.find_by(email_normalized: @email_normalized, field_name: "subscribed").last_sent_value
    end
  end

  test "subscribes a new email with initial fields and selected lists" do
    authenticate_user
    with_loops(nil) do |captured|
      patch subscriptions_path, params: { subscribed: "1", list_ids: [ "list_events" ] }
      assert_match(/subscribed to Hack Club emails/, flash[:notice])

      dispatch!
      assert_equal 1, captured.size
      payload = captured.first[:payload]
      assert_equal true, payload[:subscribed]
      assert_equal SubscriptionsController::NEW_CONTACT_SOURCE, payload[:source]
      assert_equal "Hack Clubber", payload[:userGroup]
      assert_equal({ "list_events" => true }, payload[:mailingLists])
      assert LoopsListSubscription.exists?(email_normalized: @email_normalized, list_id: "list_events")
      assert_equal %w[mailingList:list_events source subscribed userGroup],
        LoopsContactChangeAudit.where(email_normalized: @email_normalized).pluck(:field_name).sort
    end
  end

  test "new email gets default public list pre-checked" do
    ENV["DEFAULT_LOOPS_LIST_ID"] = "list_news"
    authenticate_user
    with_loops(nil) do
      get subscriptions_path
      assert_match(/isn't on Hack Club's email list yet/, response.body)
      assert_select "input#list_list_news[checked]"
      assert_select "input[type=submit][value=Subscribe]"
    end
  end

  test "toggles lists, ignores private list ids, and records opt-outs" do
    authenticate_user
    contact = { "email" => @email, "subscribed" => true, "mailingLists" => { "list_news" => true } }
    with_loops(contact) do |captured|
      patch subscriptions_path, params: { subscribed: "1", list_ids: [ "list_events", "list_private" ] }
      assert_match(/mailing list changes are saved/, flash[:notice])
      assert_equal({ "list_news" => false, "list_events" => true }, last_envelope.payload.dig("mailingLists", "value"))

      dispatch!
      assert_equal 1, captured.size
      assert_equal({ mailingLists: { "list_news" => false, "list_events" => true } }, captured.first[:payload])

      # Opt-out is remembered so the Airtable sync won't re-add the list
      assert LoopsListSubscription.exists?(email_normalized: @email_normalized, list_id: "list_news")
      audit = LoopsContactChangeAudit.find_by(email_normalized: @email_normalized, field_name: "mailingList:list_news")
      assert_equal "unsubscribe", audit.strategy
      assert_equal "Newsletter", audit.provenance.dig("list", "name")
    end
  end

  test "unsubscribing leaves list memberships alone" do
    authenticate_user
    with_loops({ "email" => @email, "subscribed" => true, "mailingLists" => { "list_news" => true } }) do |captured|
      patch subscriptions_path, params: { subscribed: "0", list_ids: [] }
      assert_match(/unsubscribed/, flash[:notice])

      dispatch!
      assert_equal [ { email: @email_normalized, payload: { subscribed: false } } ], captured
    end
  end

  test "no changes does not queue anything" do
    authenticate_user
    with_loops({ "email" => @email, "subscribed" => true, "mailingLists" => { "list_news" => true } }) do |captured|
      patch subscriptions_path, params: { subscribed: "1", list_ids: [ "list_news" ] }
      assert_equal "No changes detected", flash[:notice]
      assert_nil last_envelope
    end
  end

  test "edit shows pending changes before they are sent, and the change log after" do
    authenticate_user
    with_loops({ "email" => @email, "subscribed" => true, "mailingLists" => { "list_news" => true } }) do
      patch subscriptions_path, params: { subscribed: "1", list_ids: [ "list_events" ] }

      get subscriptions_path
      assert_match(/Saving your latest changes/, response.body)
      assert_select "input#list_list_news:not([checked])"
      assert_select "input#list_list_events[checked]"
      assert_select ".change-log li", text: /Leave Newsletter, Join Events.*saving/m

      # A second submit diffs against the pending state, not stale Loops state
      patch subscriptions_path, params: { subscribed: "1", list_ids: [ "list_events" ] }
      assert_equal "No changes detected", flash[:notice]

      dispatch!
    end

    with_loops({ "email" => @email, "subscribed" => true, "mailingLists" => { "list_events" => true } }) do
      get subscriptions_path
      assert_no_match(/Saving your latest changes/, response.body)
      assert_select ".change-log li", text: /Joined Events.*you, on this page/m
      assert_select ".change-log li", text: /Left Newsletter/
    end
  end

  test "a failed send marks the envelope failed, writes no audit, and shows in the change log" do
    authenticate_user
    with_loops({ "email" => @email, "subscribed" => false, "mailingLists" => {} }) do
      patch subscriptions_path, params: { subscribed: "1" }
    end

    failing = ->(**args) { raise LoopsService::ApiError.new(500, '{"message":"boom"}') }
    with_singleton_method_stub(LoopsService, :find_contact, ->(**args) { [ { "email" => @email, "subscribed" => false } ] }) do
      with_singleton_method_stub(LoopsService, :update_contact, failing) do
        dispatch!
      end
    end

    assert last_envelope.failed?
    assert_equal "self_service", last_envelope.error["stage"]
    assert_equal 0, LoopsContactChangeAudit.where(email_normalized: @email_normalized).count

    with_loops({ "email" => @email, "subscribed" => false, "mailingLists" => {} }) do
      get subscriptions_path
      assert_select ".change-log li", text: /Subscribe to Hack Club emails.*failed/m
    end
  end

  test "switch email link returns to subscriptions after verifying" do
    authenticate_user
    get auth_change_email_path(redirect_to: subscriptions_path)
    assert_response :success

    new_email = "subs-test-2@example.com"
    code = nil
    with_singleton_method_stub(LoopsService, :send_transactional_email, ->(*args, **kwargs) { { "success" => true } }) do
      original = AuthenticationService.method(:generate_otp)
      with_singleton_method_stub(AuthenticationService, :generate_otp, ->(email) { code = original.call(email) }) do
        post auth_change_email_request_path, params: { email: new_email }
      end
    end
    post auth_otp_verify_path, params: { code: code }
    assert_redirected_to subscriptions_path
  ensure
    n = EmailNormalizer.normalize("subs-test-2@example.com")
    OtpVerification.where(email_normalized: n).delete_all
    AuthenticatedSession.where(email_normalized: n).delete_all
    REDIS_FOR_RATE_LIMITING.del("rate:otp:#{n}")
  end
end
