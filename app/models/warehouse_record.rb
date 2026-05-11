class WarehouseRecord < ApplicationRecord
  self.abstract_class = true

  # Use Rails multiple database support with replica: true
  # The replica: true flag in database.yml prevents Rails from checking migrations on this database
  # Connect to warehouse_readonly database
  # Rails will raise an error if the config doesn't exist, which is fine
  connects_to database: { writing: :warehouse_readonly, reading: :warehouse_readonly }
end
