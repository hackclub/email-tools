#!/usr/bin/env ruby
# Temporary script to resubscribe alt emails that were unsubscribed during testing
# Usage: rails runner scripts/resubscribe_alts.rb

emails = [
  "zach+71322@hackclub.com",
  "zach+8183@hackclub.com",
  "zach+airtable-to-loops-v2-test2@hackclub.com",
  "zach+airtable-to-loops-v2-test@hackclub.com",
  "zach+firsttest@hackclub.com",
  "zach+loopsapitest222@hackclub.com",
  "zach+loopsapitest224@hackclub.com",
  "zach+loopsapitest2@hackclub.com",
  "zach+test9999@hackclub.com",
  "zach+testcider@hackclub.com"
]

puts "=== Resubscribing #{emails.length} alt emails ==="
puts ""

success_count = 0
error_count = 0

emails.each_with_index do |email, i|
  puts "[#{i+1}/#{emails.length}] Resubscribing #{email}..."

  begin
    response = LoopsService.update_contact(email: email, subscribed: true)

    if response && response["success"] == true
      puts "  ✓ Successfully resubscribed"
      success_count += 1
    else
      puts "  ✗ Failed: API returned success=false"
      error_count += 1
    end
  rescue => e
    puts "  ✗ Error: #{e.class} - #{e.message}"
    error_count += 1
  end
end

puts ""
puts "=== Summary ==="
puts "Successfully resubscribed: #{success_count}"
puts "Errors: #{error_count}"
puts "Total: #{emails.length}"
