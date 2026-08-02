# Wires the "Preview optimized resume" button on the resume show page (issue
# #17) to Resume::CachedOptimization, which wraps Resume::Optimization (#13)
# and its BulletRewriter/LlmCallGuard calls. job_description_text itself is
# never persisted — same request-param pattern JobDescriptionsController (#16)
# already uses; what the cache holds is a digest of it plus the rewrites, for
# Resume::CachedOptimization::CACHE_TTL (issue #83, ADR-0021).
#
# The download path (#18) reads through the same cache, so within that window
# what this action renders is exactly what gets downloaded. Outside it — an
# expired entry, or an edited job description — the download re-runs the
# pipeline and its rewrites will differ from these. The preview is binding for
# the window, not in general; ADR-0021 records why that tradeoff beats failing
# the download.
class PreviewsController < ApplicationController
  def create
    @resume = find_owned_resume!(params[:resume_id])
    @job_description_text = params[:job_description_text].to_s

    if @job_description_text.blank?
      flash.now[:alert] = "Please paste a job description first."
      template = "resumes/show"
      status = :unprocessable_entity
    elsif @job_description_text.length > MAX_JOB_DESCRIPTION_LENGTH
      flash.now[:alert] = "That job description is too long (maximum #{MAX_JOB_DESCRIPTION_LENGTH} characters). Please shorten it and try again."
      template = "resumes/show"
      status = :unprocessable_entity
    else
      @optimized_resume = Resume::CachedOptimization.call(
        resume: @resume, job_description_text: @job_description_text, context: :preview
      )
      template = "previews/show"
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
end
