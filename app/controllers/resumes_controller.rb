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

    # After the two cheap rejections above, before the Anthropic request inside
    # Resume::Import (issue #22).
    enforce_quota!(:resume_extraction)

    resume = Resume::Import.call(file: params[:file], strategy: DEFAULT_STRATEGY)
    # last_accessed_at starts the issue #59 retention clock immediately, rather
    # than leaving it nil (which would read as the never-claimed/orphan case)
    # until the user's first subsequent visit.
    resume.update!(owner_token: current_owner_token, last_accessed_at: Time.current)

    redirect_to resume_path(resume)
  rescue ActiveRecord::RecordInvalid, Resume::Import::UnsupportedFormatError => e
    flash.now[:alert] = "We couldn't process that file: #{e.message}"
    render :new, status: :unprocessable_entity
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError,
         Resume::Extractors::JsonMapper::InvalidJsonError => e
    # Log class only — PDF parser messages may include binary PDF bytes; JSON
    # parser messages include the temp file path. Neither is PII, but neither
    # is useful enough to justify the risk of leaking unexpected content.
    #
    # Note: InvalidJsonError is only raised by the "regex" strategy (JsonMapper).
    # The default "llm" strategy reads JSON as raw text and never reaches this
    # path. This rescue becomes live only if the "regex" strategy is exposed to
    # end users in the future.
    Rails.logger.warn("ResumesController: unreadable upload (#{e.class})")
    flash.now[:alert] = "We couldn't read that file — it may be corrupted or in an unsupported format. Please try exporting again."
    render :new, status: :unprocessable_entity
  end

  def show
    @resume = find_owned_resume!(params[:id])
  end
end
