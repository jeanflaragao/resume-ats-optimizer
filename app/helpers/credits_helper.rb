# Issue #122: the credit balance must be visible, and a Preview/Download
# button must say what clicking it will cost, before the click -- not after.
module CreditsHelper
  def credit_balance_label(user)
    if unlimited_window_active?(user)
      "Unlimited until #{user.unlimited_until.to_date.to_fs(:long)}"
    else
      "#{pluralize(user.credits, "credit")} remaining"
    end
  end

  # [button label suffix, disabled?] for a Preview/Download submit button.
  # A nil suffix leaves the button's existing label untouched -- job_description_text
  # isn't known server-side yet (the page's first render, before "Check match"
  # has ever run), so there is nothing to price. Once it is known,
  # Resume::CachedOptimization.cached? decides "free" without running the
  # pipeline or acquiring its lock; Credit.available? decides the rest.
  def optimization_cost_status(resume:, job_description_text:)
    return [ nil, false ] if job_description_text.blank?

    if Resume::CachedOptimization.cached?(resume: resume, job_description_text: job_description_text)
      [ "— free, already generated", false ]
    elsif Credit.available?(Current.user)
      [ "— uses 1 credit", false ]
    else
      [ "— out of credits", true ]
    end
  end

  private

  def unlimited_window_active?(user)
    user.unlimited_until.present? && Time.current < user.unlimited_until
  end
end
