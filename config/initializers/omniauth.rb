# Google OAuth (issue #120, ADR-0032). Credentials are validated at boot in
# production by Authentication::ConfigGuard (config/initializers/
# authentication_config_guard.rb) — a blank ENV var here just means sign-in
# fails at the provider handshake, which is the expected local-dev state
# before an operator registers their own Google OAuth client (see
# docs/railway-deploy-runbook.md).
#
# No per-environment callback URL branching: omniauth-google-oauth2 builds the
# callback URL from the incoming request's own host, so localhost:3000 in dev
# and the Railway domain in production each produce the correct URL on their
# own. The only per-environment difference is which redirect URIs are
# registered against this one OAuth client in Google Cloud Console.
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2, ENV["GOOGLE_OAUTH_CLIENT_ID"], ENV["GOOGLE_OAUTH_CLIENT_SECRET"],
    scope: "email,profile"
end

# OmniAuth 2.x's own default — restated explicitly rather than relied on
# silently, since omniauth-rails_csrf_protection (Gemfile) depends on the
# request phase being POST-only to close the login-CSRF hole OmniAuth::Builder
# no longer closes by itself.
OmniAuth.config.allowed_request_methods = [ :post ]

# Lets test/integration/authentication_test.rb (and any future test touching
# sign-in) stub a Google response via OmniAuth.config.mock_auth instead of
# performing a real provider handshake.
OmniAuth.config.test_mode = true if Rails.env.test?
