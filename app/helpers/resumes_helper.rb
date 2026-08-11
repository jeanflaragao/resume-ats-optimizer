# Flattens a resume's own pending_items with each experience's/education's
# into one list for resumes/show.html.erb to render as a single quiet
# section -- ADR-0031: measured at ~0-2 items per resume, so this stays a
# short list with an inline form per row, not a dedicated panel/page.
module ResumesHelper
  PendingItemRow = Data.define(:scope, :position, :field, :kind, :reason, :raw_value)

  def pending_item_rows(resume)
    rows = resume.pending_items.map { |item| pending_item_row("resume", nil, item) }
    resume.experiences.each do |experience|
      rows.concat(experience.pending_items.map { |item| pending_item_row("experience", experience.position, item) })
    end
    resume.educations.each do |education|
      rows.concat(education.pending_items.map { |item| pending_item_row("education", education.position, item) })
    end
    rows
  end

  # A whole dropped experience/education entry (field "experience"/
  # "education") is deliberately excluded from PendingItemsController::
  # FILLABLE_FIELDS -- see that controller's header. Reusing its allowlist
  # here rather than duplicating it keeps "what's fillable" defined in one
  # place.
  def pending_item_fillable?(row)
    PendingItemsController::FILLABLE_FIELDS.include?(row.field)
  end

  def pending_item_label(row)
    case row.field
    when "starts_on" then "Start date"
    when "ends_on" then "End date"
    when "skill" then "Skill"
    when "bullet" then "Bullet point"
    when "experience" then "Experience entry"
    when "education" then "Education entry"
    when "experiences" then "Experience entries"
    when "bullets" then "Bullet points"
    else row.field.capitalize
    end
  end

  private

  def pending_item_row(scope, position, item)
    PendingItemRow.new(
      scope: scope, position: position, field: item["field"], kind: item["kind"],
      reason: item["reason"], raw_value: item["raw_value"]
    )
  end
end
