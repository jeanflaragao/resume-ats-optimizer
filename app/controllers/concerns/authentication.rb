# Mandatory-accounts gate (issue #120, ADR-0032): no anonymous session can
# reach any action in this app. Mirrors the architecture Rails 8's own
# `bin/rails generate authentication` produces (Current/Session/
# resume_session/start_new_session_for), since ADR-0007 already anchored this
# project on that shape once real auth landed — only the credential check
# differs (Google OAuth via SessionsController#create, not
# User.authenticate_by).
#
# Deliberately independent of current_owner_token/find_owned_resume!/
# enforce_quota! below in ApplicationController: this concern decides *who is
# signed in*, not *which resumes a signed-in visitor can see* — that
# owner_token-to-user_id migration is issue #121, not this one.
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private
    def authenticated?
      resume_session
    end

    def require_authentication
      resume_session || request_authentication
    end

    def resume_session
      Current.session ||= find_session_by_cookie
    end

    def find_session_by_cookie
      Session.find_by(id: cookies.signed[:session_id]) if cookies.signed[:session_id]
    end

    def request_authentication
      session[:return_to_after_authenticating] = request.url
      redirect_to new_session_path
    end

    def after_authentication_url
      session.delete(:return_to_after_authenticating) || root_url
    end

    def start_new_session_for(user)
      user.sessions.create!(user_agent: request.user_agent, ip_address: request.remote_ip).tap do |session|
        Current.session = session
        cookies.signed.permanent[:session_id] = { value: session.id, httponly: true, same_site: :lax }
      end
    end

    def terminate_session
      Current.session.destroy
      cookies.delete(:session_id)
    end
end
