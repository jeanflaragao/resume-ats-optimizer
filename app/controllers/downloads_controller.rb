# Issue #18: enqueues Resume::OptimizedPdfJob and serves its finished bytes.
#
# This is the one path where job_description_text IS persisted, and the comment
# here used to claim otherwise. It has to be: the work happens off the request
# thread, so the text must outlive the request that carried it, and passing it
# as an Active Job argument meant Solid Queue writing it to
# solid_queue_jobs.arguments in plaintext with no retention bound for a job that
# failed (issue #76). It now goes to an encrypted Resume::PdfRequest that the
# job destroys on success and Resume::PdfRequest.purge_stale! collects
# otherwise; the queue only carries its id. ADR-0022.
#
# JobDescriptionsController (#16) and PreviewsController (#17) are synchronous
# and genuinely never persist it -- that half of the old claim was true, and is
# what made the exception here easy to miss.
class DownloadsController < ApplicationController
  # Fallback for a real race confirmed via manual testing: Resume::OptimizedPdfJob
  # can finish and broadcast its Turbo Stream update before the status page's
  # ActionCable subscription has connected -- broadcasts aren't queued for late
  # subscribers, so that update is just lost, leaving "Generating..." stuck
  # forever even though the download is actually ready. downloads/pending.html.erb's
  # Stimulus controller hits this once on connect to catch that case directly,
  # without needing full polling.
  def ready
    cached = Rails.cache.read(Resume::OptimizedPdfJob.cache_key(params[:id]))
    return head :no_content if cached.nil?

    find_owned_resume!(cached[:resume_id])

    # A failed job records its reason under the same key, so this fallback can
    # tell "failed" from "still running" instead of reporting no_content
    # forever when the failure broadcast was lost to #72's race.
    if cached[:error]
      render partial: "downloads/failed", locals: { message: cached[:error] }
    else
      render partial: "downloads/ready", locals: { download_id: params[:id] }
    end
  rescue ActiveRecord::RecordNotFound
    # Issue #114: a download_id owned by a different session must be indistinguishable
    # from one that never existed, matching the property #show already has (ADR-0029) --
    # otherwise the response itself (this 404 vs. the 204 above) tells a session holding
    # someone else's id that the id is real. 204 rather than 404 specifically because it's
    # the status the two already-safe branches above (nonexistent, not-yet-cached) share;
    # download_status_controller.js only branches on response.ok, which both a 204 and a
    # 404 already satisfy identically (204 is ok with a guaranteed-empty body; 404 exits
    # the fetch handler via the !response.ok guard) -- confirmed by reading it, not assumed.
    head :no_content
  end
  def create
    @resume = find_owned_resume!(params[:resume_id])
    job_description_text = params[:job_description_text].to_s
    unusable_error = usability_error
    unrenderable_error = renderability_error

    if job_description_text.blank?
      flash.now[:alert] = "Please paste a job description first."
      template = "resumes/show"
      status = :unprocessable_entity
    elsif job_description_text.length > MAX_JOB_DESCRIPTION_LENGTH
      flash.now[:alert] = "That job description is too long (maximum #{MAX_JOB_DESCRIPTION_LENGTH} characters). Please shorten it and try again."
      template = "resumes/show"
      status = :unprocessable_entity
    elsif unusable_error
      # Issue #122, case 2 — same relative position as guard_renderable! below
      # (ADR-0025): free, deterministic, and knowable from @resume's own
      # persisted attributes, so it must run before anything downstream is
      # spent on a resume that can't produce anything usable.
      flash.now[:alert] = unusable_error.user_message
      template = "resumes/show"
      status = :unprocessable_entity
    elsif unrenderable_error
      # Checked before enforce_quota! below, deliberately -- see ADR-0025. Every
      # field Resume::Pdf.guard_renderable! walks is a real Resume/Experience/
      # Education attribute that exists right here, before any LLM call, so a
      # refusal that's knowable this early must not cost a pdf_generation slot
      # the way a refusal from inside the job legitimately would. Safe to log
      # the message, same reasoning Resume::OptimizedPdfJob already relies on:
      # this error carries only a Unicode block name and a count (ADR-0015).
      Rails.logger.error("DownloadsController refused resume #{@resume.id}: #{unrenderable_error.class} (#{unrenderable_error.message})")
      flash.now[:alert] = unrenderable_error.user_message
      template = "resumes/show"
      status = :unprocessable_entity
    elsif !credit_available_for_this_download?(job_description_text)
      # Issue #122. A 0-credit user may still download something already
      # cached (a free hit) -- only refused when this specific (resume, job
      # description) pair would be a genuine, chargeable miss.
      flash.now[:alert] = "You're out of credits. This resume hasn't been optimized against this job description before, " \
                           "so generating it would use one."
      template = "resumes/show"
      status = :unprocessable_entity
    else
      # Before the row and before the enqueue, so a refused download leaves no
      # job-description copy on disk and never occupies a worker (issue #22).
      # This is also why Resume::OptimizedPdfJob needs no handler for
      # Usage::Quota::ExceededError the way it needs one for the global cap:
      # the job cannot be reached with the quota already spent.
      enforce_quota!(:pdf_generation)

      # Issue #76: the text goes into an encrypted, short-lived Resume::PdfRequest
      # and the queue gets its id. Passing it as a job argument put it in
      # solid_queue_jobs.arguments in plaintext, with no retention bound for
      # jobs that failed.
      pdf_request = Resume::PdfRequest.create!(
        resume: @resume, download_id: SecureRandom.uuid, text: job_description_text
      )
      @download_id = pdf_request.download_id

      # resume_id and download_id stay as arguments alongside the reference.
      # Both are non-sensitive (a bigint and a random uuid) and the job's failure
      # path needs them without the record: record_failure broadcasts to
      # download_id and writes resume_id for DownloadsController#ready's
      # ownership check, so a pdf_request_id-only signature would leave an
      # expired or purged request stuck on "Generating..." -- the exact hang
      # ADR-0018 closed.
      Resume::OptimizedPdfJob.perform_later(
        resume_id: @resume.id,
        pdf_request_id: pdf_request.id,
        download_id: @download_id
      )

      # Issue #66: redirect rather than render, so the address bar carries
      # download_id from the moment the job is enqueued. A refresh is then a
      # real GET #show can reconstruct state from, instead of a turbo_stream
      # swap that leaves no trace once the page reloads. No respond_to/format
      # branching needed here -- a 3xx has no body to content-negotiate.
      return redirect_to download_path(@download_id)
    end

    respond_to do |format|
      format.html { render template, status: status }
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.update("flash", partial: "layouts/flash"),
          turbo_stream.update("main_content", template: template)
        ], status: status
      end
    end
  end

  # Issue #66: the single, ownership-gated entry point for every state a
  # download_id can be in -- in progress (a Resume::PdfRequest still exists,
  # nothing cached yet), ready (cached bytes), failed (cached error), or
  # unknown/expired (neither). #create now redirects here immediately on
  # enqueue, so this also has to be reachable well before the job finishes.
  def show
    cached = Rails.cache.read(Resume::OptimizedPdfJob.cache_key(params[:id]))
    pdf_request = Resume::PdfRequest.find_by(download_id: params[:id]) if cached.nil?
    resume_id = cached&.dig(:resume_id) || pdf_request&.resume_id
    resume = resume_id && find_owned_resume!(resume_id)

    if resume.nil?
      flash[:alert] = "That download link has expired. Please generate a new one."
      return redirect_to root_path
    end

    if cached && cached[:bytes].present?
      send_data cached[:bytes], filename: "#{resume.name.presence || 'resume'}.pdf",
        type: "application/pdf", disposition: "attachment"
    elsif cached
      flash[:alert] = cached[:error] || Resume::OptimizedPdfJob::GENERIC_FAILURE_MESSAGE
      redirect_to root_path
    else
      render "downloads/pending", formats: [ :html ], locals: { download_id: params[:id] }
    end
  rescue ActiveRecord::RecordNotFound
    # A download_id owned by a different session must be indistinguishable
    # from one that never existed -- otherwise the response itself (404 here
    # vs. the redirect above) tells a session holding someone else's id that
    # the id is real. Every other find_owned_resume! call site deliberately
    # lets this fall through to Rails' default 404 (see ApplicationController);
    # this is a one-method exception, not a change to that convention, because
    # #show is the one place download_id -- now a real, copyable URL since the
    # #create redirect above -- can be probed directly.
    flash[:alert] = "That download link has expired. Please generate a new one."
    redirect_to root_path
  end

  private

    # nil when @resume is usable, or the raised error otherwise — same shape
    # as renderability_error below.
    def usability_error
      Resume::CachedOptimization.guard_usable!(resume: @resume)
      nil
    rescue Resume::CachedOptimization::UnusableResumeError => e
      e
    end

    # nil when @resume renders fine, or the raised error otherwise. A plain
    # method rather than a boolean predicate so #create can log and build the
    # user-facing message from the same error object without guarding twice.
    def renderability_error
      Resume::Pdf.guard_renderable!(resume: @resume)
      nil
    rescue Resume::Pdf::UnrenderableCharacterError => e
      e
    end

    # Same free-hit exception PreviewsController's credit gate has: a 0-credit
    # user may still download an (resume, job description) pair that's already
    # cached from an earlier preview or download.
    def credit_available_for_this_download?(job_description_text)
      Credit.available?(Current.user) ||
        Resume::CachedOptimization.cached?(resume: @resume, job_description_text: job_description_text)
    end
end
