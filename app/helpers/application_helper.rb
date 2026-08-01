module ApplicationHelper
  # Same formatting Resume::Pdf uses for experience/education date ranges,
  # reused here so the HTML preview (issue #17) reads consistently with the
  # eventual PDF download.
  def date_range(starts_on, ends_on)
    return nil if starts_on.blank? && ends_on.blank?

    start_text = starts_on&.strftime("%b %Y")
    end_text = ends_on ? ends_on.strftime("%b %Y") : "Present"
    [ start_text, end_text ].compact.join(" - ")
  end
end
