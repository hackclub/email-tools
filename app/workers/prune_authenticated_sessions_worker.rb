class PruneAuthenticatedSessionsWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default

  # Default pruning window: 1 day (delete expired sessions older than 1 day)
  DEFAULT_PRUNING_WINDOW_DAYS = 1

  def perform(pruning_window_days = nil)
    cutoff = (pruning_window_days || DEFAULT_PRUNING_WINDOW_DAYS).days.ago

    # Delete expired authenticated sessions older than cutoff
    deleted_count = AuthenticatedSession.where("expires_at < ?", cutoff).in_batches.delete_all

    # Log the pruning operation
    Rails.logger.info("Pruned #{deleted_count} expired authenticated sessions older than #{cutoff}")

    deleted_count
  end
end
