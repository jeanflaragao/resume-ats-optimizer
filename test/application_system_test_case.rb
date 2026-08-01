require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ] do |driver_option|
    # Chrome refuses to launch as a non-root user without these inside a
    # container (see Dockerfile.dev's non-root "rails" user) -- unrelated to
    # this app's own sandboxing, just how Chrome's own sandbox interacts with
    # Docker's namespace restrictions.
    driver_option.add_argument("--no-sandbox")
    driver_option.add_argument("--disable-dev-shm-usage")
  end
end
