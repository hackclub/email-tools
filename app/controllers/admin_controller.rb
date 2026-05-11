class AdminController < ApplicationController
  def index
    redirect_to admin_emails_path
  end
end
