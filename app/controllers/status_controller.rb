# Public, unauthenticated system-health page so anyone can see whether the
# email-tools pipeline is keeping up instead of it failing silently. It only
# ever shows aggregate counts and durations (see SystemStatus) — no emails,
# source names, or record data.
class StatusController < ApplicationController
  skip_before_action :authenticate_admin

  def show
    @status = SystemStatus.snapshot

    respond_to do |format|
      format.html
      format.json { render json: @status }
    end
  end
end
