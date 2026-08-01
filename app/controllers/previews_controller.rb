# Wires the "Preview optimized resume" button on the resume show page (issue
# #17) to the already-existing Resume::Optimization (#13), which itself calls
# BulletRewriter/LlmCallGuard. job_description_text is never persisted — same
# request-param pattern JobDescriptionsController (#16) already uses. No
# caching against #18's own (separate) Resume::Optimization call — see
# CLAUDE.md's Resume::Optimization entry for why that's deferred.
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
      @optimized_resume = Resume::Optimization.call(resume: @resume, job_description_text: @job_description_text)
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
