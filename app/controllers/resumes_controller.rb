# "regex" is a lesser-fidelity fallback (can't even extract name/email/phone,
# see Resume::Extractors::PdfRegex) not meant for end users to choose between
# — the strategy stays a hidden implementation detail, defaulting to "llm".
class ResumesController < ApplicationController
  DEFAULT_STRATEGY = "llm"

  def new
  end

  def create
    if params[:file].blank?
      flash.now[:alert] = "Please choose a file to upload."
      return render :new, status: :unprocessable_entity
    end

    resume = Resume::Import.call(file: params[:file], strategy: DEFAULT_STRATEGY)
    resume.update!(owner_token: current_owner_token)

    redirect_to resume_path(resume)
  rescue ActiveRecord::RecordInvalid, Resume::Import::UnsupportedFormatError => e
    flash.now[:alert] = "We couldn't process that file: #{e.message}"
    render :new, status: :unprocessable_entity
  end

  def show
    @resume = Resume.find_by!(id: params[:id], owner_token: current_owner_token)
  end
end
