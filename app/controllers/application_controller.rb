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

  # Cross-cutting rescue handlers for LLM-pipeline errors that can surface in
  # any of the three LLM-calling controllers (Resumes, JobDescriptions,
  # Previews). Each redirects rather than re-rendering because the handler
  # doesn't have access to the controller-specific instance variables
  # (e.g. @resume) needed to safely re-render the right template.
  #
  # File-parsing errors (PDF::Reader, InvalidJsonError) are intentionally NOT
  # here — they are specific to ResumesController#create and are handled
  # there by an extended rescue clause with the right template context.
  #
  # ActiveRecord::RecordNotFound is intentionally NOT listed — it must fall
  # through to Rails' default 404 so owner-scoping tests remain correct.
  #
  # Logging: exception class + HTTP status code when the error carries one —
  # never e.message. RubyLLM::Error#message falls back to response&.body (raw
  # Anthropic API JSON) which could contain request content in edge cases. A
  # status code is metadata (429, 401, 529 are three distinct operational
  # problems), not user content, so it is safe to include.
  rescue_from LlmCallGuard::DailyLimitExceededError do |e|
    Rails.logger.warn("#{controller_name}##{action_name}: #{e.class}")
    redirect_back_or_to root_path, flash: { alert: "We've hit today's processing limit. Please try again tomorrow." }
  end

  rescue_from BulletRewriter::MismatchedBulletCountError do |e|
    Rails.logger.warn("#{controller_name}##{action_name}: #{e.class}")
    redirect_back_or_to root_path, flash: { alert: "We had trouble rewriting your resume bullets. Please try again." }
  end

  rescue_from RubyLLM::Error do |e|
    status = e.response&.status
    Rails.logger.error("#{controller_name}##{action_name}: #{e.class}#{" (HTTP #{status})" if status}")
    redirect_back_or_to root_path, flash: { alert: "The AI service is temporarily unavailable. Please try again in a moment." }
  end

  rescue_from Faraday::Error do |e|
    # response_status returns nil for connection-level failures (ConnectionFailed,
    # TimeoutError) that never received an HTTP response — omit the suffix in
    # that case rather than emitting a misleading "(HTTP )".
    status = e.response_status
    Rails.logger.error("#{controller_name}##{action_name}: #{e.class}#{" (HTTP #{status})" if status}")
    redirect_back_or_to root_path, flash: { alert: "The AI service is temporarily unavailable. Please try again in a moment." }
  end

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
