require "test_helper"

class AuthenticationTest < ActionDispatch::IntegrationTest
  def mock_google_auth(email: "tester@example.com", uid: "google-uid-1")
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: { email: email, name: "Tester", image: nil },
      extra: { raw_info: { email_verified: true } }
    )
  end

  teardown do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  # OmniAuth's test-mode request phase (mock_request_call) still redirects to
  # the callback URL, exactly like the real request phase redirects to Google
  # -- it's only the callback request that carries the mocked auth hash
  # (mock_callback_call). One follow_redirect! reaches it.
  test "signing in with Google creates a user and session, and lands back on the resume index" do
    mock_google_auth

    assert_difference [ "User.count", "Identity.count", "Session.count" ], 1 do
      post "/auth/google_oauth2"
      follow_redirect!
    end
    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
  end

  test "signing out clears the session, so the previously-reachable resume index redirects to sign-in again" do
    mock_google_auth
    post "/auth/google_oauth2"
    follow_redirect!

    delete session_path
    get root_path

    assert_redirected_to new_session_path
  end

  # The literal acceptance criterion (issue #120): enforcement must be
  # server-side, not just a hidden sign-in link. A hand-crafted POST with no
  # session at all must be refused before ResumesController#create ever runs
  # -- proven here by asserting no Resume is created, not just by asserting a
  # redirect (a redirect after the work already happened would be a weaker,
  # wrong-shaped test).
  test "a hand-crafted POST to the upload endpoint with no session is refused, not processed" do
    assert_no_difference "Resume.count" do
      post resumes_path
    end
    assert_redirected_to new_session_path
  end
end
