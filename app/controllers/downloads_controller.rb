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
  # forever even though the download is actually ready. downloads/create.html.erb's
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
  end
  def create
    @resume = find_owned_resume!(params[:resume_id])
    job_description_text = params[:job_description_text].to_s
    unrenderable_error = renderability_error

    if job_description_text.blank?
      flash.now[:alert] = "Please paste a job description first."
      template = "resumes/show"
      status = :unprocessable_entity
    elsif job_description_text.length > MAX_JOB_DESCRIPTION_LENGTH
      flash.now[:alert] = "That job description is too long (maximum #{MAX_JOB_DESCRIPTION_LENGTH} characters). Please shorten it and try again."
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
      template = "downloads/create"
      status = :ok
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

  def show
    cached = Rails.cache.read(Resume::OptimizedPdfJob.cache_key(params[:id]))

    if cached.nil? || cached[:bytes].blank?
      flash[:alert] = cached&.dig(:error) || "That download link has expired. Please generate a new one."
      return redirect_to root_path
    end

    resume = find_owned_resume!(cached[:resume_id])
    send_data cached[:bytes], filename: "#{resume.name.presence || 'resume'}.pdf",
      type: "application/pdf", disposition: "attachment"
  end

  private

    # nil when @resume renders fine, or the raised error otherwise. A plain
    # method rather than a boolean predicate so #create can log and build the
    # user-facing message from the same error object without guarding twice.
    def renderability_error
      Resume::Pdf.guard_renderable!(resume: @resume)
      nil
    rescue Resume::Pdf::UnrenderableCharacterError => e
      e
    end
end
