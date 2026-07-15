Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Public home page
  root "home#index"

  # Public system-health dashboard (aggregate metrics only, no private data)
  get "internal-dashboard", to: "status#show", as: :internal_dashboard

  # Public auth routes
  get "auth/otp/request", to: "auth#show_otp_request", as: :auth_otp_request
  post "auth/otp/request", to: "auth#request_otp"
  get "auth/otp/verify", to: "auth#show_verify_otp", as: :auth_otp_verify
  post "auth/otp/verify", to: "auth#verify_otp"
  delete "auth/logout", to: "auth#logout", as: :auth_logout
  get "auth/change_email", to: "auth#show_change_email", as: :auth_change_email
  post "auth/change_email/request", to: "auth#change_email_request_otp", as: :auth_change_email_request

  # Profile update routes (require OTP auth, NOT admin auth)
  get "profile/edit", to: "profile_update#edit", as: :profile_edit
  patch "profile", to: "profile_update#update", as: :profile

  # Alt email management routes (require OTP auth)
  get "alts", to: "alts#index", as: :alts
  post "alts/unsubscribe", to: "alts#unsubscribe", as: :alts_unsubscribe

  # Admin routes (behind HTTP auth)
  scope "/admin" do
    # Admin root redirects to emails
    get "", to: "admin#index", as: :admin_root

    # Sidekiq Web UI with HTTP Basic Auth
    require "sidekiq/web"
    require_relative "../app/middleware/authenticated_sidekiq_web"
    mount AuthenticatedSidekiqWeb.new => "/sidekiq"

    # Email audit log viewer
    get "emails", to: "emails#index", as: :admin_emails
    get "emails/*email", to: "emails#show", as: "admin_email_audit_log", format: false

    # Sync sources management
    post "sync_sources/ignore", to: "sync_sources#ignore", as: :admin_sync_sources_ignore
    delete "sync_sources/ignore", to: "sync_sources#unignore", as: :admin_sync_sources_unignore
    post "sync_sources/:id/restore", to: "sync_sources#restore", as: :admin_sync_source_restore
    resources :sync_sources, path: "sync_sources", as: "admin_sync_sources"
  end
end
