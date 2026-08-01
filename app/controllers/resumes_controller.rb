# "regex" is a lesser-fidelity fallback (can't even extract name/email/phone,
# see Resume::Extractors::PdfRegex) not meant for end users to choose between
# — the strategy stays a hidden implementation detail, defaulting to "llm".
class ResumesController < ApplicationController
  DEFAULT_STRATEGY = "llm"

  # Upper bound on uploaded file size. Beyond ~2–3 MB of PDF content, extracted
  # text approaches claude-sonnet-4-5's 200,000-token context ceiling; 10 MB is
  # a generous but firm limit that keeps both token usage and memory pressure
  # bounded without rejecting any realistic resume or LinkedIn export.
  MAX_UPLOAD_BYTES = 10 * 1024 * 1024 # 10 MB

  def new
  end

  def create
    if params[:file].blank?
      flash.now[:alert] = "Please choose a file to upload."
      return render :new, status: :unprocessable_entity
    end

    if params[:file].size > MAX_UPLOAD_BYTES
      flash.now[:alert] = "That file is too large (maximum #{MAX_UPLOAD_BYTES / 1024 / 1024} MB). Please upload a smaller file."
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
    @resume = find_owned_resume!(params[:id])
  end
end
