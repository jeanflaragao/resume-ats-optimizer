# Wires the job-description textarea on a resume's show page (issue #16) to
# the already-existing deterministic pipeline (JobDescription::Extractor,
# Comparison, MatchScore). job_description_text is never persisted — it's
# passed straight through as a request param, same as those services already
# expect.
class JobDescriptionsController < ApplicationController
  def create
    @resume = find_owned_resume!(params[:resume_id])
    @job_description_text = params[:job_description_text].to_s

    if @job_description_text.blank?
      flash.now[:alert] = "Please paste a job description."
      status = :unprocessable_entity
    elsif @job_description_text.length > MAX_JOB_DESCRIPTION_LENGTH
      flash.now[:alert] = "That job description is too long (maximum #{MAX_JOB_DESCRIPTION_LENGTH} characters). Please shorten it and try again."
      status = :unprocessable_entity
    else
      requirements = JobDescription::Extractor.call(text: @job_description_text)
      @comparison = Comparison.call(resume: @resume, requirements: requirements)
      @match_score = MatchScore.call(comparison: @comparison)
      status = :ok
    end

    respond_to do |format|
      format.html { render "resumes/show", status: status }
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.update("flash", partial: "layouts/flash"),
          turbo_stream.update("main_content", template: "resumes/show")
        ], status: status
      end
    end
  end
end
