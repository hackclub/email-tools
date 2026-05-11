namespace :loops do
  desc "Refresh all known contacts from Loops API (queues workers for each email)"
  task refresh_all_contacts: :environment do
    puts "Finding all known contact emails..."

    # Get unique emails from all sources that track contacts
    emails_from_baselines = LoopsFieldBaseline.distinct.pluck(:email_normalized)
    emails_from_audits = LoopsContactChangeAudit.distinct.pluck(:email_normalized)
    emails_from_subscriptions = LoopsListSubscription.distinct.pluck(:email_normalized)

    # Combine and deduplicate
    all_emails = (emails_from_baselines + emails_from_audits + emails_from_subscriptions).uniq

    puts "Found #{all_emails.size} unique contact email(s)"

    if all_emails.empty?
      puts "No contacts found to refresh."
      exit
    end

    # Queue workers for each email
    queued_count = 0
    all_emails.each do |email|
      RefreshContactFromLoopsWorker.perform_async(email)
      queued_count += 1
    end

    puts "Queued #{queued_count} contact refresh job(s)"
    puts "Workers will process jobs from the Sidekiq queue."
    puts "Monitor progress in Sidekiq UI or logs."
  end

  desc "Refresh a single contact by email (queues worker)"
  task :refresh_contact, [ :email ] => :environment do |_t, args|
    email = args[:email]
    unless email
      puts "Usage: rake loops:refresh_contact[email@example.com]"
      exit 1
    end

    puts "Queueing refresh for contact: #{email}"
    RefreshContactFromLoopsWorker.perform_async(email)
    puts "Queued refresh job for #{email}"
  end
end
