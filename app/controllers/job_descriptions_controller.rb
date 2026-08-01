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
      return render "resumes/show", status: :unprocessable_entity
    end

    requirements = JobDescription::Extractor.call(text: @job_description_text)
    @comparison = Comparison.call(resume: @resume, requirements: requirements)
    @match_score = MatchScore.call(comparison: @comparison)

    render "resumes/show"
  end
end
