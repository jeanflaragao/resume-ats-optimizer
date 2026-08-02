# Renders a Resume as an ATS-friendly PDF: a single-column, image-free layout
# (Header, Summary, Experience, Education, Skills) that plain-text ATS parsers
# can read reliably. Deliberately simple per the Stack section's rationale for
# choosing Prawn over an HTML/Chrome renderer.
#
# Fonts are embedded rather than using Prawn's built-in AFM faces, which are
# Windows-1252 only and crashed on any name outside it (issue #74, ADR-0018).
# Liberation Sans is the body face -- metric-compatible with Helvetica, so
# swapping it moved no layout -- with DejaVu Sans as a fallback purely for the
# handful of glyphs Liberation lacks (U+2011, U+2713).
class Resume::Pdf
  # Raised instead of rendering a character no embedded font can display.
  # Prawn does not raise for a missing glyph: it draws .notdef (nothing
  # visible) while the ToUnicode CMap still extracts the original text, so a
  # CJK resume would download "successfully" with a blank name line and parse
  # cleanly in an ATS. Failing loudly is the only honest option -- see ADR-0018.
  class UnrenderableCharacterError < StandardError
    attr_reader :blocks

    def initialize(counts_by_block)
      @blocks = counts_by_block.keys
      super(counts_by_block.map { |block, count| "#{count} characters in #{block}" }.join("; "))
    end
  end

  # Only the blocks a resume plausibly contains, named for a human reading a
  # log line. Anything outside this list falls back to a generic label rather
  # than emitting a codepoint -- see #unicode_block.
  UNICODE_BLOCKS = {
    (0x3040..0x309F) => "Hiragana",
    (0x30A0..0x30FF) => "Katakana",
    (0x3400..0x4DBF) => "CJK Unified Ideographs Extension A",
    (0x4E00..0x9FFF) => "CJK Unified Ideographs",
    (0xAC00..0xD7AF) => "Hangul Syllables",
    (0x0590..0x05FF) => "Hebrew",
    (0x0600..0x06FF) => "Arabic",
    (0x0900..0x097F) => "Devanagari",
    (0x2190..0x21FF) => "Arrows",
    (0x2600..0x27BF) => "Miscellaneous Symbols",
    (0x1F300..0x1FAFF) => "Emoji and Pictographs"
  }.freeze

  FONT_DIR = Rails.root.join("vendor/fonts")
  BODY_FONT = "LiberationSans".freeze
  FALLBACK_FONT = "DejaVuSans".freeze

  FONT_FAMILIES = {
    BODY_FONT => {
      normal: FONT_DIR.join("LiberationSans-Regular.ttf").to_s,
      bold: FONT_DIR.join("LiberationSans-Bold.ttf").to_s
    },
    # Registered normal-only on purpose: Prawn's fallback always resolves to
    # the normal weight, so a bold face here would never be selected.
    FALLBACK_FONT => {
      normal: FONT_DIR.join("DejaVuSans.ttf").to_s
    }
  }.freeze

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
    @document.font_families.update(FONT_FAMILIES)
    @document.font(BODY_FONT)
    @document.fallback_fonts([ FALLBACK_FONT ])
    @document.font_size = BODY_FONT_SIZE
    @document.fill_color = BODY_COLOR
  end

  def call
    guard_renderable!
    render_header
    render_summary
    render_experience
    render_education
    render_skills
    document.render
  end

  private

  attr_reader :resume, :document

  # Walks every string that will be drawn and refuses the whole document if any
  # character has no glyph in either embedded font. Deliberately all-or-nothing:
  # dropping or substituting the offending characters would be transliteration
  # by another name, and silently printing "Balka" for "Bałka" on someone's
  # resume is exactly what ADR-0018 rejects.
  def guard_renderable!
    counts = Hash.new(0)

    renderable_text.each do |string|
      string.to_s.each_char do |char|
        next if char.match?(/\s/) || renderable?(char)

        counts[unicode_block(char)] += 1
      end
    end

    raise UnrenderableCharacterError, counts if counts.any?
  end

  # Every dynamic string the render_* methods below pass to document.text. The
  # static section headers, SEPARATOR and BULLET_PREFIX are ASCII by
  # construction and formatted dates are ASCII in the default locale, so only
  # user-supplied values need checking.
  def renderable_text
    [
      resume.name, resume.email, resume.phone, resume.summary,
      *Array(resume.skills),
      *resume.experiences.flat_map { |e| [ e.company, e.title, e.location, *Array(e.bullets) ] },
      *resume.educations.flat_map { |e| [ e.school, e.degree, e.field_of_study ] }
    ].compact
  end

  def renderable?(char)
    font_cmaps.any? { |cmap| (cmap[char.ord] || 0) != 0 }
  end

  def font_cmaps
    @font_cmaps ||= FONT_FAMILIES.values.flat_map(&:values).map do |path|
      TTFunk::File.open(path).cmap.unicode.first
    end
  end

  # ADR-0015: for a CJK name the codepoints ARE the name, so a log line listing
  # "U+5F35 U+5049" leaks precisely what logging the raw string would. The block
  # name plus a count is the most specific thing that is safe to emit.
  def unicode_block(char)
    UNICODE_BLOCKS.find { |range, _| range.cover?(char.ord) }&.last || "an unsupported script"
  end

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
