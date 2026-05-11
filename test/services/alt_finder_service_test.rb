require "test_helper"
require "minitest/mock"

class AltFinderServiceTest < ActiveSupport::TestCase
  def setup
    @main_email = "zach@hackclub.com"
    @user_part = "zach"
    @domain_part = "hackclub.com"
  end

  test "finds subscribed and unsubscribed alt emails matching plus-alias pattern" do
    # Mock warehouse DB connection and LoopsAudience queries
    mock_subscribed_alts = [
      "zach+test@hackclub.com",
      "zach+test2@hackclub.com"
    ]

    mock_unsubscribed_alts = [
      "zach+old@hackclub.com",
      "zach+something@hackclub.com"
    ]

    # Create chainable mock relations for subscribed query
    mock_order_subscribed = Object.new
    mock_order_subscribed.define_singleton_method(:order) { |*args| mock_order_subscribed }
    mock_order_subscribed.define_singleton_method(:pluck) { |*args| mock_subscribed_alts }

    mock_where_subscribed = Object.new
    mock_where_subscribed.define_singleton_method(:where) { |*args, **kwargs| mock_order_subscribed }
    mock_where_subscribed.define_singleton_method(:order) { |*args| mock_order_subscribed }

    # Create chainable mock relations for unsubscribed query
    mock_order_unsubscribed = Object.new
    mock_order_unsubscribed.define_singleton_method(:order) { |*args| mock_order_unsubscribed }
    mock_order_unsubscribed.define_singleton_method(:pluck) { |*args| mock_unsubscribed_alts }

    mock_where_unsubscribed = Object.new
    mock_where_unsubscribed.define_singleton_method(:where) { |*args, **kwargs| mock_order_unsubscribed }
    mock_where_unsubscribed.define_singleton_method(:order) { |*args| mock_order_unsubscribed }

    # Mock the base_query that handles chained where calls
    # The service calls: base_query.where(subscribed: true) and base_query.where("subscribed = ? OR subscribed IS NULL", false)
    mock_base_query = Object.new
    call_count = 0
    mock_base_query.define_singleton_method(:where) do |*args, **kwargs|
      call_count += 1
      # First where call is subscribed: true (keyword arg)
      if call_count == 1 && kwargs[:subscribed] == true
        mock_where_subscribed
      # Second where call is unsubscribed query (string SQL)
      elsif call_count == 2 && args.length > 0 && args[0].is_a?(String) && args[0].include?("subscribed")
        mock_where_unsubscribed
      # Fallback for subscribed
      elsif kwargs[:subscribed] == true
        mock_where_subscribed
      # Fallback for unsubscribed
      elsif args.length > 0 && args[0].is_a?(String) && args[0].include?("subscribed")
        mock_where_unsubscribed
      else
        mock_where_subscribed
      end
    end
    mock_base_query.define_singleton_method(:order) { |*args| mock_base_query }
    mock_base_query.define_singleton_method(:pluck) { |*args| [] }

    # Models with connects_to automatically route queries - no need to stub connected_to
    LoopsAudience.stub(:where, ->(*args, **kwargs) { mock_base_query }) do
      result = AltFinderService.call(main_email: @main_email)
      assert_equal mock_subscribed_alts, result[:subscribed]
      assert_equal mock_unsubscribed_alts, result[:unsubscribed]
    end
  end

  test "returns empty arrays when no alts found" do
    mock_order = Object.new
    mock_order.define_singleton_method(:order) { |*args| mock_order }
    mock_order.define_singleton_method(:pluck) { |*args| [] }

    mock_where2 = Object.new
    mock_where2.define_singleton_method(:where) { |**kwargs| mock_order }
    mock_where2.define_singleton_method(:order) { |*args| mock_order }

    mock_where1 = Object.new
    mock_where1.define_singleton_method(:where) { |*args, **kwargs| mock_where2 }

    # Models with connects_to automatically route queries - no need to stub connected_to
    LoopsAudience.stub(:where, mock_where1) do
      result = AltFinderService.call(main_email: @main_email)
      assert_equal [], result[:subscribed]
      assert_equal [], result[:unsubscribed]
    end
  end

  test "raises error for blank main_email" do
    assert_raises(ArgumentError) do
      AltFinderService.call(main_email: "")
    end

    assert_raises(ArgumentError) do
      AltFinderService.call(main_email: nil)
    end
  end

  test "returns empty arrays for invalid email format" do
    # When email doesn't have @, split returns nil and service returns empty hash
    result = AltFinderService.call(main_email: "invalid-email")
    assert_equal [], result[:subscribed]
    assert_equal [], result[:unsubscribed]
  end

  test "handles SQL special characters in user part without error" do
    # Test that emails with special characters like % don't cause SQL injection
    email_with_special_chars = "zach%test@hackclub.com"

    mock_order = Object.new
    mock_order.define_singleton_method(:order) { |*args| mock_order }
    mock_order.define_singleton_method(:pluck) { |*args| [] }

    mock_where2 = Object.new
    mock_where2.define_singleton_method(:where) { |**kwargs| mock_order }
    mock_where2.define_singleton_method(:order) { |*args| mock_order }

    mock_where1 = Object.new
    mock_where1.define_singleton_method(:where) { |*args, **kwargs| mock_where2 }

    # Models with connects_to automatically route queries - no need to stub connected_to
    LoopsAudience.stub(:where, mock_where1) do
      # Should not raise an error even with special characters
      result = AltFinderService.call(main_email: email_with_special_chars)
      assert_equal [], result[:subscribed]
      assert_equal [], result[:unsubscribed]
    end
  end

  test "uses WarehouseRecord.connected_to instead of ApplicationRecord.connected_to" do
    # This test verifies that we're using the correct connection scope.
    # WarehouseRecord has its own connects_to mapping, so we must use
    # WarehouseRecord.connected_to, not ApplicationRecord.connected_to.
    # Otherwise, queries may run against the wrong database.

    mock_subscribed_alts = [ "zach+test@hackclub.com" ]
    mock_unsubscribed_alts = []

    # Create mock for subscribed query
    mock_order_subscribed = Object.new
    mock_order_subscribed.define_singleton_method(:order) { |*args| mock_order_subscribed }
    mock_order_subscribed.define_singleton_method(:pluck) { |*args| mock_subscribed_alts }
    mock_where_subscribed = Object.new
    mock_where_subscribed.define_singleton_method(:where) { |*args, **kwargs| mock_order_subscribed }
    mock_where_subscribed.define_singleton_method(:order) { |*args| mock_order_subscribed }

    # Create mock for unsubscribed query
    mock_order_unsubscribed = Object.new
    mock_order_unsubscribed.define_singleton_method(:order) { |*args| mock_order_unsubscribed }
    mock_order_unsubscribed.define_singleton_method(:pluck) { |*args| mock_unsubscribed_alts }
    mock_where_unsubscribed = Object.new
    mock_where_unsubscribed.define_singleton_method(:where) { |*args, **kwargs| mock_order_unsubscribed }
    mock_where_unsubscribed.define_singleton_method(:order) { |*args| mock_order_unsubscribed }

    # Mock the base_query that handles chained where calls
    mock_base_query = Object.new
    call_count = 0
    mock_base_query.define_singleton_method(:where) do |*args, **kwargs|
      call_count += 1
      # First where call is subscribed: true (keyword arg)
      if call_count == 1 && kwargs[:subscribed] == true
        mock_where_subscribed
      # Second where call is unsubscribed query (string SQL)
      elsif call_count == 2 && args.length > 0 && args[0].is_a?(String) && args[0].include?("subscribed")
        mock_where_unsubscribed
      # Fallback for subscribed
      elsif kwargs[:subscribed] == true
        mock_where_subscribed
      # Fallback for unsubscribed
      elsif args.length > 0 && args[0].is_a?(String) && args[0].include?("subscribed")
        mock_where_unsubscribed
      else
        mock_where_subscribed
      end
    end
    mock_base_query.define_singleton_method(:order) { |*args| mock_base_query }
    mock_base_query.define_singleton_method(:pluck) { |*args| [] }

    # Track whether WarehouseRecord.connected_to is called
    warehouse_record_called = false
    application_record_called = false

    # Stub WarehouseRecord.connected_to to verify it's called
    WarehouseRecord.stub(:connected_to, ->(role:, &block) {
      warehouse_record_called = true
      assert_equal :reading, role, "connected_to should be called with role: :reading"
      block.call
    }) do
      # Stub ApplicationRecord.connected_to to verify it's NOT called
      ApplicationRecord.stub(:connected_to, ->(*args, **kwargs, &block) {
        application_record_called = true
        block.call if block
      }) do
        LoopsAudience.stub(:where, ->(*args, **kwargs) { mock_base_query }) do
          result = AltFinderService.call(main_email: @main_email)
          assert_equal mock_subscribed_alts, result[:subscribed]
          assert_equal mock_unsubscribed_alts, result[:unsubscribed]
        end
      end
    end

    assert warehouse_record_called, "WarehouseRecord.connected_to should be called"
    refute application_record_called, "ApplicationRecord.connected_to should NOT be called"
  end
end
