class ApplicationController < ActionController::Base
  include Authentication

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

  # Distinct from the daily cap above: the guard refuses when it cannot read
  # its own counter (a cache outage), rather than proceeding uncounted. That is
  # transient and self-clearing, so the advice is "in a moment" — telling a user
  # to come back tomorrow because Postgres hiccuped would be wrong.
  rescue_from LlmCallGuard::BudgetUnavailableError do |e|
    Rails.logger.error("#{controller_name}##{action_name}: #{e.class}")
    redirect_back_or_to root_path, flash: { alert: "We can't process resumes right now. Please try again in a moment." }
  end

  # Issue #22's per-subject quota, distinct from both handlers above. The two
  # LlmCallGuard errors are about the service as a whole — "we"; this one is
  # about this session specifically — "you" — and the wording has to make that
  # difference legible, because the remedy is different. A user who hits the
  # global cap can do nothing but wait; a user who hits their own quota has
  # been told, accurately, that they are the reason.
  #
  # Logs the exception class and the action type. The action type is an
  # internal enum from Usage::Quota::ACTION_TYPES, not user content. The
  # subject token is deliberately absent: it is the session credential
  # find_owned_resume! authorizes against, so logging it would put a working
  # key to someone's resume in the log file (ADR-0015).
  rescue_from Usage::Quota::ExceededError do |e|
    Rails.logger.warn("#{controller_name}##{action_name}: #{e.class} (#{e.action})")
    redirect_back_or_to root_path, flash: { alert:
      "You've reached your daily limit for #{Usage::Quota.label_for(e.action)} " \
      "(#{e.limit} per day). Please try again tomorrow." }
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
  # (ResumesController#show, JobDescriptionsController#create,
  # PreviewsController#create, DownloadsController#create/#ready/#show).
  #
  # Also the single choke point for Resume::LAST_ACCESSED_PURGE_AFTER (issue
  # #59): every read path routes through here, so bumping last_accessed_at
  # once at this call site covers all of them rather than each controller
  # remembering to do it.
  #
  # update_column, not update!/touch: Resume::CachedOptimization's cache key
  # is derived from cache_key_with_version, which is derived from updated_at.
  # Touching updated_at here would invalidate the optimization cache on every
  # page view/preview/download click, defeating ADR-0021 (one preview-then-
  # download pays for one bullet-rewrite fan-out, not two). update_column
  # skips both validations and the updated_at touch.
  def find_owned_resume!(id)
    Resume.find_by!(id: id, owner_token: current_owner_token).tap do |resume|
      resume.update_column(:last_accessed_at, Time.current)
    end
  end

  # Issue #22. Charges one use of `action` to this session and raises
  # Usage::Quota::ExceededError — handled by the rescue_from above — if that
  # puts it over the daily limit.
  #
  # Called explicitly at the top of each quotaed action rather than declared as
  # a before_action, because in three of the four it has to run *after* the
  # existing blank/length guards: rejecting an over-long job description
  # (MAX_JOB_DESCRIPTION_LENGTH) costs nothing, so it must not cost a slot
  # either. A before_action runs before the action body and could not express
  # that ordering.
  #
  # Placed before any work in every case — before Resume::Import, before the
  # extractor, before Resume::CachedOptimization, and in DownloadsController
  # before both the Resume::PdfRequest write and the perform_later. Failing
  # here spends no Anthropic request, no Solid Queue worker, and writes no
  # job-description row.
  def enforce_quota!(action)
    Usage::Quota.consume!(subject: current_owner_token, action: action)
  end
end
