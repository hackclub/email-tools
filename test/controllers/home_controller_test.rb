require "test_helper"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "should get index without authentication" do
    get root_url
    assert_response :success
    assert_match(/Change profile information/i, response.body)
  end

  test "should not require authentication for root path" do
    get root_url
    assert_response :success
  end
end
