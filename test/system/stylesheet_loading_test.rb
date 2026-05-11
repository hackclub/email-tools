require "application_system_test_case"

class StylesheetLoadingTest < ApplicationSystemTestCase
  test "stylesheet link tag references application.css" do
    visit root_path

    # Get the HTML source
    html = page.html

    # Verify stylesheet link tag exists and references application
    assert_match %r{<link[^>]*href=["'][^"']*application[^"']*["'][^>]*rel=["']stylesheet["']}, html,
      "HTML should include a stylesheet link tag referencing application.css"

    # Verify it's not referencing :app (the incorrect reference)
    assert_no_match %r{/assets/app-}, html,
      "Stylesheet should not reference 'app', should reference 'application'"

    # Verify the stylesheet link tag exists via Capybara
    stylesheet_link = page.find('link[rel="stylesheet"]', visible: false)
    href = stylesheet_link[:href]

    # Verify href contains /assets/application-
    assert_match %r{/assets/application-}, href,
      "Stylesheet href should reference application.css with fingerprint"
  end
end
