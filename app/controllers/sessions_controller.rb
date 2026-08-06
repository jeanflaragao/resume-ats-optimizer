class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create failure ]

  def new
  end

  # The OmniAuth callback target (config/routes.rb: GET /auth/:provider/callback),
  # not a form submission — request.env["omniauth.auth"] is populated by the
  # OmniAuth::Builder middleware (config/initializers/omniauth.rb) before this
  # action ever runs.
  def create
    user = Authentication::FindOrCreateUser.call(auth: request.env["omniauth.auth"])
    start_new_session_for(user)
    redirect_to after_authentication_url
  rescue Authentication::FindOrCreateUser::UnverifiedEmailError
    redirect_to new_session_path, alert: "Your Google account's email isn't verified. Please verify it with Google and try again."
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end

  # OmniAuth's own failure redirect (denied consent, provider timeout, etc.).
  # params[:message] is one of OmniAuth's own short failure codes (e.g.
  # "invalid_credentials", "access_denied"), not user-entered content, so
  # logging it directly carries no ADR-0015 concern.
  def failure
    Rails.logger.warn("SessionsController#failure: #{params[:message]}")
    redirect_to new_session_path, alert: "Sign-in was cancelled or failed. Please try again."
  end
end
