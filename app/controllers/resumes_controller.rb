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

  # Issue #121. The signed-in user's own resume history — root points here
  # (config/routes.rb) so a returning user lands on their own work instead of
  # an empty upload form, which is the visible payoff of durable ownership.
  def index
    @resumes = Current.user.resumes.order(last_accessed_at: :desc)
  end

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

    # Issue #122: a binary "can you start" gate, not a charge -- the actual
    # debit happens later, at Resume::CachedOptimization's cache-miss, not
    # here. Ahead of the readability guard below and enforce_quota!: extraction
    # is a real, measured Anthropic request (R$0.29 for a heavy CV) with no
    # revenue path for a 0-credit user, so it's refused before spending
    # anything, the same "check before charging" shape as every guard below.
    unless Credit.available?(Current.user)
      flash.now[:alert] = "You're out of credits, so we can't start a new upload right now. " \
                           "Your existing resumes and downloads are still available from your history."
      return render :new, status: :unprocessable_entity
    end

    # Issue #122, case 1: a scanned-image PDF with no text layer. Native,
    # before any LLM call -- see Resume::PdfReadabilityGuard. JSON uploads
    # have no equivalent failure mode (a JSON parse failure is handled by the
    # InvalidJsonError rescue below, not this guard).
    if pdf_upload? && !readable_pdf?
      flash.now[:alert] = "We could not read any text in this PDF; it may be a scanned image."
      return render :new, status: :unprocessable_entity
    end

    # After the guards above, before the Anthropic request inside
    # Resume::Import (issue #22).
    enforce_quota!(:resume_extraction)

    # Resume::Import sets user: and last_accessed_at in the same create! call
    # that persists everything else (issue #121, ADR-0034) — there is no
    # second update! here the way there was for owner_token.
    resume = Resume::Import.call(file: params[:file], strategy: DEFAULT_STRATEGY, user: Current.user)

    redirect_to resume_path(resume)
  rescue ActiveRecord::RecordInvalid, Resume::Import::UnsupportedFormatError => e
    flash.now[:alert] = "We couldn't process that file: #{e.message}"
    render :new, status: :unprocessable_entity
  rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError,
         Resume::PdfText::ExtractionError,
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

  private

    def pdf_upload?
      File.extname(params[:file].original_filename.to_s).delete_prefix(".").downcase == "pdf"
    end

    # true/false, not a guard!-style raise: unlike Resume::Pdf.guard_renderable!
    # (rescued for its own message further up in the file), this check only
    # ever needs one branch point, right here. A genuine Resume::PdfText::
    # ExtractionError (pdftotext itself failing, not merely finding little
    # text) is deliberately left to propagate into the existing rescue clause
    # below rather than being folded into this method's false — the two are
    # different facts with different messages.
    def readable_pdf?
      Resume::PdfReadabilityGuard.call!(file_path: params[:file].path.to_s)
      true
    rescue Resume::PdfReadabilityGuard::UnreadableError
      false
    end
end
