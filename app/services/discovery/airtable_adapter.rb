module Discovery
  class AirtableAdapter
    def list_ids_with_names
      list = []
      AirtableService::Bases.find_each { |b| list << { id: b["id"], name: b["name"] || b["id"] } }
      list
    rescue => e
      Rails.logger.error("AirtableAdapter failed: #{e.class} - #{e.message}")
      []
    end
  end
end
