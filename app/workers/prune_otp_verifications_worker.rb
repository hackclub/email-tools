class PruneOtpVerificationsWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default

  # Default pruning window: 30 days
  DEFAULT_PRUNING_WINDOW_DAYS = 30

  def perform(pruning_window_days = nil)
    cutoff = (pruning_window_days || DEFAULT_PRUNING_WINDOW_DAYS).days.ago

    # Delete OTP verifications older than cutoff
    deleted_count = OtpVerification.where("created_at < ?", cutoff).in_batches.delete_all

    # Log the pruning operation
    Rails.logger.info("Pruned #{deleted_count} OTP verifications older than #{cutoff}")

    deleted_count
  end
end
