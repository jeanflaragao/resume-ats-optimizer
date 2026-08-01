require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # config/environments/test.rb disables forgery protection app-wide so integration tests
  # (which never render real forms or carry tokens) don't have to fake one on every post.
  # System tests exercise the app's real data: turbo: false forms through a real browser, so
  # they opt back in for the duration of each example -- this is what actually catches CSRF
  # bugs like the formaction issue from #17/#18 (see issue #57 / ADR-0013). Restoring the
  # previous value in teardown, rather than hardcoding false, keeps this correct if
  # config/environments/test.rb's own default ever changes. Scoped to system tests only:
  # flipping this in config/environments/test.rb itself would fail every post in
  # test/integration/ for no added signal.
  setup do
    @previous_allow_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @previous_allow_forgery_protection
  end

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |driver_option|
    # Chrome refuses to launch as a non-root user without these inside a
    # container (see Dockerfile.dev's non-root "rails" user) -- unrelated to
    # this app's own sandboxing, just how Chrome's own sandbox interacts with
    # Docker's namespace restrictions.
    driver_option.add_argument("--no-sandbox")
    driver_option.add_argument("--disable-dev-shm-usage")
  end
end
