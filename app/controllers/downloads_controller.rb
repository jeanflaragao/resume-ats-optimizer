# Issue #18: enqueues Resume::OptimizedPdfJob and serves its finished bytes.
# job_description_text is never persisted -- resubmitted from the preview
# page's hidden field, same "request param only" pattern #16/#17 already use.
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
    render partial: "downloads/ready", locals: { download_id: params[:id] }
  end
  def create
    @resume = find_owned_resume!(params[:resume_id])
    job_description_text = params[:job_description_text].to_s

    if job_description_text.blank?
      flash.now[:alert] = "Please paste a job description first."
      return render "resumes/show", status: :unprocessable_entity
    end

    @download_id = SecureRandom.uuid
    Resume::OptimizedPdfJob.perform_later(
      resume_id: @resume.id,
      job_description_text: job_description_text,
      download_id: @download_id
    )
  end

  def show
    cached = Rails.cache.read(Resume::OptimizedPdfJob.cache_key(params[:id]))

    if cached.nil?
      flash[:alert] = "That download link has expired. Please generate a new one."
      return redirect_to root_path
    end

    resume = find_owned_resume!(cached[:resume_id])
    send_data cached[:bytes], filename: "#{resume.name.presence || 'resume'}.pdf",
      type: "application/pdf", disposition: "attachment"
  end
end
