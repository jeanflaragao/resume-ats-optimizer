# Wires the "Preview optimized resume" button on the resume show page (issue
# #17) to Resume::CachedOptimization, which wraps Resume::Optimization (#13)
# and its BulletRewriter/LlmCallGuard calls. This action never persists
# job_description_text — same synchronous request-param pattern
# JobDescriptionsController (#16) already uses; what the cache holds is a digest
# of it plus the rewrites, for Resume::CachedOptimization::CACHE_TTL (issue #83,
# ADR-0021).
#
# Scoped to this action deliberately, as in #16: the download path below does
# persist it, encrypted and briefly, because a background job cannot read a
# request param (issue #76, ADR-0022).
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

    unusable_error = usability_error

    if @job_description_text.blank?
      flash.now[:alert] = "Please paste a job description first."
      template = "resumes/show"
      status = :unprocessable_entity
    elsif @job_description_text.length > MAX_JOB_DESCRIPTION_LENGTH
      flash.now[:alert] = "That job description is too long (maximum #{MAX_JOB_DESCRIPTION_LENGTH} characters). Please shorten it and try again."
      template = "resumes/show"
      status = :unprocessable_entity
    elsif unusable_error
      # Issue #122, case 2 — checked before the credit gate and
      # enforce_quota! below, same reasoning as DownloadsController's
      # guard_renderable! check (ADR-0025): free, deterministic, and knowable
      # from @resume's own persisted attributes.
      flash.now[:alert] = unusable_error.user_message
      template = "resumes/show"
      status = :unprocessable_entity
    elsif !credit_available_for_this_preview?
      flash.now[:alert] = "You're out of credits. This resume hasn't been optimized against this job description before, " \
                           "so previewing it would use one."
      template = "resumes/show"
      status = :unprocessable_entity
    else
      # Charged per attempt, before Resume::CachedOptimization can report
      # whether this would have been a free cache hit. Deciding that first
      # would mean enforcing the quota inside that class, after the lock and
      # potentially after a full pipeline — which is the opposite of failing
      # fast. Sizing absorbs the re-previews (issue #22, ADR-0023).
      enforce_quota!(:bullet_rewriting)
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

  private

    # nil when @resume is usable, or the raised error otherwise — same shape
    # DownloadsController#renderability_error already uses, so #create can log
    # and build the message from the same error object without guarding twice.
    def usability_error
      Resume::CachedOptimization.guard_usable!(resume: @resume)
      nil
    rescue Resume::CachedOptimization::UnusableResumeError => e
      e
    end

    # A 0-credit user (and not inside an unlimited window) may still preview
    # something already cached — that specific request is a free hit, not a
    # new spend. Only checked once @job_description_text is known to be
    # present and within bounds; nil job_description_text is caught by the
    # blank-check branch above first.
    def credit_available_for_this_preview?
      Credit.available?(Current.user) ||
        Resume::CachedOptimization.cached?(resume: @resume, job_description_text: @job_description_text)
    end
end
