class SyncLoopsListsWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default

  # Syncs mailing lists from Loops API to local database
  #
  # This worker:
  # - Creates new lists if they don't exist
  # - Updates existing lists with latest data from Loops
  # - Deletes lists that are no longer in Loops
  # - Intentionally does NOT handle list subscriptions (those are tracked separately)
  def perform
    lists = LoopsService.list_mailing_lists
    now = Time.current

    # Get list IDs returned from API
    returned_list_ids = lists.map { |list_hash| list_hash["id"] }.to_set

    # Update or create lists that exist in Loops
    lists.each do |list_hash|
      loops_list = LoopsList.find_or_initialize_by(loops_list_id: list_hash["id"])
      loops_list.name = list_hash["name"]
      loops_list.description = list_hash["description"]
      loops_list.is_public = list_hash["isPublic"]
      loops_list.synced_at = now
      loops_list.save!
    end

    # Delete lists that are no longer in Loops API
    # Historical data is preserved in loops_list_subscriptions and loops_contact_change_audits
    lists_to_delete = LoopsList.where.not(loops_list_id: returned_list_ids)
    deleted_count = lists_to_delete.count
    lists_to_delete.find_each(&:destroy)

    if deleted_count > 0
      Rails.logger.info("SyncLoopsListsWorker: Deleted #{deleted_count} list(s) that are no longer in Loops")
    end
  rescue => e
    Rails.logger.error("SyncLoopsListsWorker: Error syncing lists: #{e.class} - #{e.message}")
    Rails.logger.error("SyncLoopsListsWorker: Backtrace: #{e.backtrace.first(5).join("\n")}")
    raise
  end
end
