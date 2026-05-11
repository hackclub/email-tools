class DiscoveryReconcilerWorker
  include Sidekiq::Worker
  sidekiq_options queue: :scheduler, retry: false

  def perform
    adapters = []
    adapters << { source: "airtable", adapter: Discovery::AirtableAdapter.new } if ENV["AIRTABLE_PERSONAL_ACCESS_TOKEN"].present?

    DiscoveryReconciler.new(adapters: adapters).call
  end
end
