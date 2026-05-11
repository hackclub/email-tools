class AltsController < ApplicationController
  skip_before_action :authenticate_admin
  before_action :require_authenticated_session

  def index
    @email = current_authenticated_email
    begin
      @alts = AltFinderService.call(main_email: @email)
    rescue => e
      Rails.logger.error("AltsController#index: Failed to find alts for #{@email}: #{e.message}")
      flash.now[:error] = "Could not retrieve +alt emails at this time. Please try again later."
      @alts = { subscribed: [], unsubscribed: [] }
    end
  end

  def unsubscribe
    main_email = current_authenticated_email
    alts_to_unsubscribe = Array.wrap(params[:alts])

    # Security check: Verify that the submitted alts are valid plus-aliases of the logged-in user.
    user_part, domain_part = main_email.split("@")
    verified_alts = alts_to_unsubscribe.select do |alt|
      alt.match?(/\A#{Regexp.escape(user_part)}\+.+@#{Regexp.escape(domain_part)}\z/i)
    end.uniq(&:downcase)

    if verified_alts.empty?
      flash[:error] = "No valid +alt emails were selected for unsubscription."
      redirect_to alts_path
      return
    end

    # Enqueue the background job
    MassUnsubscribeJob.perform_async(main_email, verified_alts)

    flash[:notice] = "Unsubscription process started for #{verified_alts.count} email(s). This may take a few minutes to complete."
    redirect_to alts_path
  end
end
