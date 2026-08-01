class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  private

  # Placeholder for real ownership until the Rails 8 auth generator lands (no
  # User model exists yet). Ties a Resume to "whoever uploaded it" via an
  # opaque per-browser-session token rather than a real account. Replace with
  # a user_id FK once auth exists — not meant to be a permanent design.
  def current_owner_token
    session[:owner_token] ||= SecureRandom.hex(32)
  end
end
