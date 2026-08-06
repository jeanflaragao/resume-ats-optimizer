# Signs a fixture/created user in for tests that aren't about authentication
# itself (issue #120's ripple: every controller now requires a session).
# Drives the real OmniAuth mock + sign-in routes rather than writing a signed
# cookie directly, so these tests exercise the same code path
# test/integration/authentication_test.rb proves works, instead of a second,
# untested shortcut that could silently drift from it.
module AuthenticationTestHelper
  def mock_google_auth_for(user, uid: "test-uid-#{user.id}")
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: { email: user.email, name: user.name, image: user.avatar_url },
      extra: { raw_info: { email_verified: true } }
    )
  end

  # For ActionDispatch::IntegrationTest. `on:` targets a session opened via
  # open_session (usage_quota_test.rb's two-independent-browsers tests) rather
  # than the default one -- each such session needs its own sign-in.
  def sign_in_as(user, on: self)
    mock_google_auth_for(user)
    on.post "/auth/google_oauth2"
    on.follow_redirect!
  ensure
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  # For ApplicationSystemTestCase. Clicks the real "Continue with Google"
  # button through Capybara/Selenium so a genuine signed cookie comes back
  # from the actual server process the browser is talking to, rather than
  # injecting one out of band.
  def sign_in_as_in_browser(user)
    mock_google_auth_for(user)
    visit new_session_path
    click_button "Continue with Google"
  ensure
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end
end
