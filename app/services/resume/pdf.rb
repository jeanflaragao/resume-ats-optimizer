# Renders a Resume as an ATS-friendly PDF: a single-column, image-free layout
# (Header, Summary, Experience, Education, Skills) that plain-text ATS parsers
# can read reliably. Deliberately simple per the Stack section's rationale for
# choosing Prawn over an HTML/Chrome renderer.
class Resume::Pdf
  ACCENT_COLOR = "1F3864"
  BODY_COLOR = "000000"
  BODY_FONT_SIZE = 10
  NAME_FONT_SIZE = 18
  SECTION_HEADER_FONT_SIZE = 12
  SEPARATOR = "  |  "
  BULLET_PREFIX = "•  "
  DIVIDER_SPACING = 4
  SECTION_SPACING = 12

  def self.call(resume:)
    new(resume: resume).call
  end

  def initialize(resume:)
    @resume = resume
    @document = Prawn::Document.new
    @document.font_size = BODY_FONT_SIZE
    @document.fill_color = BODY_COLOR
  end

  def call
    render_header
    render_summary
    render_experience
    render_education
    render_skills
    document.render
  end

  private

  attr_reader :resume, :document

  def render_header
    name = resume.name.presence
    contact = [ resume.email, resume.phone ].select(&:present?).join(SEPARATOR).presence
    return unless name || contact

    height = 0
    height += document.height_of(name, size: NAME_FONT_SIZE, style: :bold) if name
    height += document.height_of(contact, size: BODY_FONT_SIZE) if contact
    ensure_space(height)

    document.text(name, size: NAME_FONT_SIZE, style: :bold) if name
    document.text(contact, size: BODY_FONT_SIZE) if contact
    document.move_down DIVIDER_SPACING
    divider
    document.move_down SECTION_SPACING
  end

  def render_summary
    return if resume.summary.blank?

    render_section("Summary") { document.text(resume.summary, size: BODY_FONT_SIZE) }
  end

  def render_experience
    return if resume.experiences.empty?

    render_section("Experience") do
      resume.experiences.each { |experience| render_experience_entry(experience) }
    end
  end

  def render_education
    return if resume.educations.empty?

    render_section("Education") do
      resume.educations.each { |education| render_education_entry(education) }
    end
  end

  def render_skills
    skills = Array(resume.skills).select(&:present?)
    return if skills.empty?

    render_section("Skills") { document.text(skills.join(", "), size: BODY_FONT_SIZE) }
  end

  def render_section(title)
    header_height = document.height_of(title, size: SECTION_HEADER_FONT_SIZE, style: :bold)
    first_line_height = document.height_of("Ag", size: BODY_FONT_SIZE)
    ensure_space(header_height + (DIVIDER_SPACING * 2) + first_line_height)

    document.fill_color(ACCENT_COLOR)
    document.text(title, size: SECTION_HEADER_FONT_SIZE, style: :bold)
    document.fill_color(BODY_COLOR)
    document.move_down DIVIDER_SPACING
    divider
    document.move_down DIVIDER_SPACING

    yield

    document.move_down SECTION_SPACING
  end

  def render_experience_entry(experience)
    header = [ experience.title, experience.company ].select(&:present?).join(", ")
    ensure_space(document.height_of(header, size: BODY_FONT_SIZE, style: :bold))
    document.text(header, size: BODY_FONT_SIZE, style: :bold) if header.present?

    meta = [ experience.location, date_range(experience.starts_on, experience.ends_on) ].select(&:present?).join(SEPARATOR)
    document.text(meta, size: BODY_FONT_SIZE) if meta.present?

    render_bullets(experience.bullets)
    document.move_down DIVIDER_SPACING
  end

  def render_education_entry(education)
    ensure_space(document.height_of(education.school, size: BODY_FONT_SIZE, style: :bold))
    document.text(education.school, size: BODY_FONT_SIZE, style: :bold)

    detail = [ education.degree, education.field_of_study ].select(&:present?).join(", ")
    meta = [ detail, date_range(education.starts_on, education.ends_on) ].select(&:present?).join(SEPARATOR)
    document.text(meta, size: BODY_FONT_SIZE) if meta.present?

    document.move_down DIVIDER_SPACING
  end

  def render_bullets(bullets)
    Array(bullets).select(&:present?).each do |bullet|
      text = "#{BULLET_PREFIX}#{bullet}"
      ensure_space(document.height_of(text, size: BODY_FONT_SIZE))
      document.text(text, size: BODY_FONT_SIZE)
    end
  end

  def date_range(starts_on, ends_on)
    return nil if starts_on.blank? && ends_on.blank?

    start_text = starts_on&.strftime("%b %Y")
    end_text = ends_on ? ends_on.strftime("%b %Y") : "Present"
    [ start_text, end_text ].compact.join(" - ")
  end

  def divider
    document.stroke_color(ACCENT_COLOR)
    document.stroke_horizontal_rule
    document.stroke_color(BODY_COLOR)
  end

  def ensure_space(height)
    document.start_new_page if document.cursor < height
  end
end
