# Issue #18: renders #17's optimized resume as a PDF off the request thread --
# a resume with several experiences means several sequential BulletRewriter LLM
# calls (one per experience, see #9), which is too slow to do inline. Stores the
# rendered bytes in Rails.cache (Solid Cache -- no new schema/table for a
# transient artifact) and pushes a Turbo Stream update to whichever browser
# is subscribed to this download_id when done.
#
# It goes through Resume::CachedOptimization rather than re-running
# Resume::Optimization itself (issue #83): within
# Resume::CachedOptimization::CACHE_TTL of the preview this reuses the preview's
# rewrites, so the download costs nothing extra and delivers the resume the user
# actually approved on screen. On a miss it re-runs the pipeline rather than
# failing the download -- and then the bullets legitimately differ from the
# preview's. ADR-0021 has the reasoning; the miss is counted so the frequency is
# visible rather than assumed.
class Resume::OptimizedPdfJob < ApplicationJob
  queue_as :default

  # Belt to production.rb's braces (issue #76). That setting is production-only;
  # this one also covers development, where the same "Enqueued ... with
  # arguments:" line is written to log/development.log. Nothing sensitive is in
  # the arguments any more -- three ids -- so this is defence in depth against a
  # future argument, not the fix. See ADR-0022 before removing it.
  self.log_arguments = false

  CACHE_EXPIRY = 15.minutes

  GENERIC_FAILURE_MESSAGE = "Something went wrong generating your PDF. Please try again.".freeze

  DAILY_LIMIT_MESSAGE = "We've hit today's processing limit. Your resume is saved — " \
                        "please try downloading it again tomorrow.".freeze

  BUDGET_UNAVAILABLE_MESSAGE = "We can't generate PDFs right now. Your resume is saved — " \
                               "please try downloading it again in a few minutes.".freeze

  EXPIRED_REQUEST_MESSAGE = "This download request expired before we could start on it. " \
                            "Please generate a new one — your resume is saved.".freeze

  def perform(resume_id:, pdf_request_id:, download_id:)
    # find_by, not find: a missing request is an expected state, not a bug. It
    # means the row was purged before a backed-up queue reached this job
    # (Resume::PdfRequest::PURGE_AFTER), or this job already succeeded and is
    # being retried. Either way there is no input to work from -- but the page
    # is still waiting, so say so rather than dying silently and leaving it on
    # "Generating..." forever.
    pdf_request = Resume::PdfRequest.find_by(id: pdf_request_id)

    if pdf_request.nil?
      Rails.logger.warn("Resume::OptimizedPdfJob found no pdf_request #{pdf_request_id} for resume #{resume_id}")
      return record_failure(resume_id, download_id, EXPIRED_REQUEST_MESSAGE)
    end

    resume = Resume.find(resume_id)
    optimized = Resume::CachedOptimization.call(
      resume: resume, job_description_text: pdf_request.text, context: :download
    )
    pdf_bytes = Resume::Pdf.call(resume: optimized)

    Rails.cache.write(cache_key(download_id), { resume_id: resume_id, bytes: pdf_bytes }, expires_in: CACHE_EXPIRY)

    Turbo::StreamsChannel.broadcast_replace_to(
      "download_#{download_id}",
      target: "download_status",
      partial: "downloads/ready",
      locals: { download_id: download_id }
    )

    # Last, so the text outlives every step that could still need it. A failure
    # deliberately leaves the row alone -- purge_stale! collects it -- so the
    # record is not destroyed out from under a job that raised on the way here.
    pdf_request.destroy
  rescue Resume::Pdf::UnrenderableCharacterError => e
    # Safe to log the message here, unlike the blanket rescue below: this error
    # is constructed by Resume::Pdf and carries only a Unicode block name and a
    # count, never the offending characters or their codepoints (ADR-0015).
    Rails.logger.error("Resume::OptimizedPdfJob failed for resume #{resume_id}: #{e.class} (#{e.message})")
    record_failure(resume_id, download_id, e.user_message)
    raise
  rescue LlmCallGuard::DailyLimitExceededError => e
    # Named rather than left to the blanket clause below, because the generic
    # "Please try again" is wrong advice here in both directions: retrying now
    # fails identically, and retrying tomorrow would succeed. #56's rescue_from
    # handlers give the preview path an equivalent message, but they live in
    # ApplicationController and never reach a job.
    #
    # Safe to log the message, on the same grounds as the clause above: it is
    # built by LlmCallGuard from an ENV integer and a counter, and carries no
    # user content (ADR-0015).
    Rails.logger.warn("Resume::OptimizedPdfJob hit the daily LLM cap for resume #{resume_id}: #{e.class} (#{e.message})")
    record_failure(resume_id, download_id, DAILY_LIMIT_MESSAGE)
    raise
  rescue LlmCallGuard::BudgetUnavailableError => e
    # The guard could not read its own counter, so it refused rather than
    # spending uncounted. Transient and self-clearing, unlike the cap above —
    # so this one really is worth retrying, just not tomorrow.
    Rails.logger.error("Resume::OptimizedPdfJob could not verify the LLM call budget for resume #{resume_id}: #{e.class}")
    record_failure(resume_id, download_id, BUDGET_UNAVAILABLE_MESSAGE)
    raise
  rescue StandardError => e
    # Log only the exception class — never the message. This clause catches any
    # StandardError, so we can't know at this level whether e.message is safe:
    # RubyLLM::Error's message falls back to response.body (raw API JSON), which
    # could contain request content in edge cases. Class-only is always safe
    # and still sufficient to route the error to the right on-call runbook.
    Rails.logger.error("Resume::OptimizedPdfJob failed for resume #{resume_id}: #{e.class}")
    record_failure(resume_id, download_id, nil)
    raise
  end

  def self.cache_key(download_id)
    "download/#{download_id}"
  end

  private

  def cache_key(download_id)
    self.class.cache_key(download_id)
  end

  # Records the failure in the cache as well as broadcasting it. The broadcast
  # alone is not enough: it can fire before the page's ActionCable subscription
  # connects and is then lost forever (issue #72), and DownloadsController#ready
  # -- the existing fallback for exactly that race -- could previously only see
  # successes, so a missed failure left the page on "Generating..." indefinitely.
  # This is the minimum needed to make a failure observable to a late
  # subscriber; it deliberately does not touch #72's polling design.
  def record_failure(resume_id, download_id, message)
    Rails.cache.write(
      cache_key(download_id),
      { resume_id: resume_id, error: message || GENERIC_FAILURE_MESSAGE },
      expires_in: CACHE_EXPIRY
    )
    Turbo::StreamsChannel.broadcast_replace_to(
      "download_#{download_id}",
      target: "download_status",
      partial: "downloads/failed",
      locals: { message: message }
    )
  end
end
