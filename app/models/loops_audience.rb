class LoopsAudience < WarehouseRecord
  # This model represents the loops.audience table in the warehouse database
  # Uses Rails multiple database support via WarehouseRecord

  # Use schema-qualified table name to ensure ActiveRecord can find it
  # The search_path is configured in database.yml, but using schema.table ensures it works
  self.table_name = "loops.audience"

  # This model should be strictly read-only
  def readonly? = true

  before_create  { raise ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only" }
  before_update  { raise ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only" }

  # Guard bulk writes as well
  def self.insert_all(*) = raise ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only"
  def self.upsert_all(*) = raise ActiveRecord::ReadOnlyRecord, "LoopsAudience is read-only"
end
