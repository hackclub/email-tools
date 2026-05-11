class HomeController < ApplicationController
  skip_before_action :authenticate_admin

  def index
  end
end
