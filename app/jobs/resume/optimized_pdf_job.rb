# Issue #18: runs the same Resume::Optimization (#13) -> Resume::Pdf (#12)
# pipeline #17's preview already uses, but off the request thread -- a resume
# with several experiences means several sequential BulletRewriter LLM calls
# (one per experience, see #9), which is too slow to do inline. Stores the
# rendered bytes in Rails.cache (Solid Cache -- no new schema/table for a
# transient artifact) and pushes a Turbo Stream update to whichever browser
# is subscribed to this download_id when done.
class Resume::OptimizedPdfJob < ApplicationJob
  queue_as :default

  CACHE_EXPIRY = 15.minutes

  def perform(resume_id:, job_description_text:, download_id:)
    resume = Resume.find(resume_id)
    optimized = Resume::Optimization.call(resume: resume, job_description_text: job_description_text)
    pdf_bytes = Resume::Pdf.call(resume: optimized)

    Rails.cache.write(cache_key(download_id), { resume_id: resume_id, bytes: pdf_bytes }, expires_in: CACHE_EXPIRY)

    Turbo::StreamsChannel.broadcast_replace_to(
      "download_#{download_id}",
      target: "download_status",
      partial: "downloads/ready",
      locals: { download_id: download_id }
    )
  rescue StandardError => e
    # Log only the exception class — never the message. The job catches any
    # StandardError, so we can't know at this level whether e.message is safe:
    # RubyLLM::Error's message falls back to response.body (raw API JSON), which
    # could contain request content in edge cases. Class-only is always safe
    # and still sufficient to route the error to the right on-call runbook.
    Rails.logger.error("Resume::OptimizedPdfJob failed for resume #{resume_id}: #{e.class}")
    Turbo::StreamsChannel.broadcast_replace_to(
      "download_#{download_id}",
      target: "download_status",
      partial: "downloads/failed"
    )
    raise
  end

  def self.cache_key(download_id)
    "download/#{download_id}"
  end

  private

  def cache_key(download_id)
    self.class.cache_key(download_id)
  end
end
