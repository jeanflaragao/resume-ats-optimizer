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
      return render "resumes/show", status: :unprocessable_entity
    end

    @optimized_resume = Resume::Optimization.call(resume: @resume, job_description_text: @job_description_text)

    render :show
  end
end
