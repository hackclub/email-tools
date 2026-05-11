require "test_helper"

class ValueNormalizerTest < ActiveSupport::TestCase
  test "unwraps single-element arrays" do
    assert_equal "x", ValueNormalizer.from_airtable([ "x" ])
  end

  test "empty array -> nil" do
    assert_nil ValueNormalizer.from_airtable([])
  end

  test "trims strings and blanks -> nil" do
    assert_equal "Zach", ValueNormalizer.from_airtable("  Zach  ")
    assert_nil ValueNormalizer.from_airtable("   ")
  end

  test "multi-element arrays preserved" do
    assert_equal [ "a", "b" ], ValueNormalizer.from_airtable([ "a", "b" ])
  end

  test "nil handling" do
    assert_nil ValueNormalizer.from_airtable(nil)
  end

  test "handles nested single-element arrays" do
    assert_equal "test", ValueNormalizer.from_airtable([ [ "test" ] ])
  end

  test "handles arrays with nil elements" do
    assert_equal "x", ValueNormalizer.from_airtable([ "x", nil ])
    assert_nil ValueNormalizer.from_airtable([ nil ])
  end

  test "handles other types unchanged" do
    assert_equal 123, ValueNormalizer.from_airtable(123)
    assert_equal true, ValueNormalizer.from_airtable(true)
    assert_equal false, ValueNormalizer.from_airtable(false)
  end
end
