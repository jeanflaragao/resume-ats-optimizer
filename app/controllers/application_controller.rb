class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Upper bound on job_description_text across every controller that receives
  # it (JobDescriptionsController, PreviewsController, DownloadsController).
  # Real job postings are 500–2,000 words (~3,000–12,000 chars). 20,000 chars
  # is ~2–3× the largest realistic posting and keeps token usage per LLM call
  # well inside claude-sonnet-4-5's 200,000-token context window even when the
  # text is embedded once per experience bullet-rewrite call.
  MAX_JOB_DESCRIPTION_LENGTH = 20_000

  private

  # Placeholder for real ownership until the Rails 8 auth generator lands (no
  # User model exists yet). Ties a Resume to "whoever uploaded it" via an
  # opaque per-browser-session token rather than a real account. Replace with
  # a user_id FK once auth exists — not meant to be a permanent design.
  def current_owner_token
    session[:owner_token] ||= SecureRandom.hex(32)
  end

  # Shared owner-scoped lookup for any controller acting on a Resume
  # (ResumesController#show, JobDescriptionsController#create).
  def find_owned_resume!(id)
    Resume.find_by!(id: id, owner_token: current_owner_token)
  end
end
