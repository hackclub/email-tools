class AltFinderService
  def self.call(main_email:)
    raise ArgumentError, "main_email cannot be blank" if main_email.blank?

    user_part, domain_part = main_email.split("@", 2)
    return { subscribed: [], unsubscribed: [] } unless user_part && domain_part

    # Construct a safe pattern for SQL ILIKE (case-insensitive).
    # We escape '%' and '_' to prevent them from being treated as wildcards if they appear in the user part.
    escaped_user_part = user_part.gsub(/([%_])/, '\\\\\1')
    pattern = "#{escaped_user_part}+%@#{domain_part}"

    # Use Rails multi-database support via WarehouseRecord.connects_to
    # According to Rails 8 docs, we need to use connected_to(role:) to switch connections
    # Since WarehouseRecord connects to warehouse_readonly for both reading and writing,
    # we use role: :reading to switch to the reading role
    # This is thread-safe (uses thread-local storage)
    # Ensure we switch the connection role for the warehouse mapping,
    # not the primary app database.
    WarehouseRecord.connected_to(role: :reading) do
      base_query = LoopsAudience.where("email ILIKE ? ESCAPE '\\'", pattern)

      subscribed = base_query
        .where(subscribed: true)
        .order(:email)
        .pluck(:email)

      # Include both false and NULL as unsubscribed (NULL typically means unsubscribed)
      unsubscribed = base_query
        .where("subscribed = ? OR subscribed IS NULL", false)
        .order(:email)
        .pluck(:email)

      {
        subscribed: subscribed,
        unsubscribed: unsubscribed
      }
    end
  end
end
