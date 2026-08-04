# Renders a Resume as an ATS-friendly PDF: a single-column, image-free layout
# (Header, Summary, Experience, Education, Skills) that plain-text ATS parsers
# can read reliably. Deliberately simple per the Stack section's rationale for
# choosing Prawn over an HTML/Chrome renderer.
#
# Fonts are embedded rather than using Prawn's built-in AFM faces, which are
# Windows-1252 only and crashed on any name outside it (issue #74, ADR-0018).
# Liberation Sans is the body face -- metric-compatible with Helvetica, so
# swapping it moved no layout -- with DejaVu Sans as a fallback purely for the
# handful of glyphs Liberation lacks (U+2011, U+2713), and Noto Sans CJK
# (Simplified Chinese) as a second fallback for CJK ideographs, Hiragana,
# Katakana and Hangul that neither of the first two cover (issue #81, ADR-0024).
class Resume::Pdf
  # Raised instead of rendering a character no embedded font can display, or a
  # character from a script whose correct rendering needs text shaping Prawn
  # cannot do. Prawn does not raise for a missing glyph: it draws .notdef
  # (nothing visible) while the ToUnicode CMap still extracts the original
  # text, so a CJK resume would download "successfully" with a blank name line
  # and parse cleanly in an ATS. And a script requiring shaping -- Hebrew,
  # Arabic, Devanagari -- has real glyphs but no bidi reordering or letter
  # joining, so Prawn draws it fluently wrong instead of refusing it. Both are
  # the same failure by different routes: silently printing a different name
  # than the one typed. See ADR-0018 and ADR-0024.
  class UnrenderableCharacterError < StandardError
    attr_reader :missing_glyph_blocks, :shaping_required_blocks

    def initialize(missing_glyph_counts:, shaping_required_counts:)
      @missing_glyph_blocks = missing_glyph_counts.keys
      @shaping_required_blocks = shaping_required_counts.keys

      segments = []
      if missing_glyph_counts.any?
        segments << missing_glyph_counts.map { |block, count| "#{count} characters in #{block} cannot be rendered" }.join("; ")
      end
      if shaping_required_counts.any?
        segments << shaping_required_counts.map { |block, count| "#{count} characters in #{block} require text shaping we do not support" }.join("; ")
      end

      super(segments.join("; "))
    end

    # Union of both reasons, for callers that only need to know which scripts
    # were involved (unchanged shape from before missing-glyph/shaping-required
    # were tracked separately).
    def blocks
      missing_glyph_blocks + shaping_required_blocks
    end

    # Shared by DownloadsController (refuses before spending pdf_generation
    # quota, issue #92/ADR-0025) and Resume::OptimizedPdfJob (the backstop for
    # characters a bullet rewrite introduces after that point), so the
    # block-to-phrase mapping and the two-reason wording live in one place
    # instead of being duplicated at both call sites. "Cannot be rendered" and
    # "requires text shaping we do not support" are different facts and read
    # differently, per ADR-0024. Only ever emits the fixed English labels
    # below, never the offending characters (ADR-0015).
    def user_message
      segments = []
      if missing_glyph_blocks.any?
        segments << "contains #{subjects_for(missing_glyph_blocks)} that our PDF template doesn't support yet"
      end
      if shaping_required_blocks.any?
        segments << "contains #{subjects_for(shaping_required_blocks)} that need right-to-left or other complex text layout our PDF template doesn't support"
      end

      "We can't generate a PDF for this resume — it #{segments.join(', and it also ')}. " \
      "The preview on screen shows them correctly. Retrying will not help; support for this is being tracked."
    end

    private

      def subjects_for(blocks)
        blocks.filter_map { |block| Resume::Pdf::USER_FACING_LABELS[block] }.uniq.presence&.to_sentence || "characters"
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

  # Maps a Unicode block name onto phrasing a candidate would recognise, for
  # UnrenderableCharacterError#user_message. Names the script without echoing
  # any of the user's own text (ADR-0015).
  USER_FACING_LABELS = {
    "CJK Unified Ideographs" => "Chinese, Japanese, or Korean characters",
    "CJK Unified Ideographs Extension A" => "Chinese, Japanese, or Korean characters",
    "Hiragana" => "Japanese characters",
    "Katakana" => "Japanese characters",
    "Hangul Syllables" => "Korean characters",
    "Hebrew" => "Hebrew characters",
    "Arabic" => "Arabic characters",
    "Devanagari" => "Devanagari characters",
    "Emoji and Pictographs" => "emoji",
    "Miscellaneous Symbols" => "symbols",
    "Arrows" => "symbols"
  }.freeze

  # Scripts we have glyph coverage for (per cmap) but refuse anyway, because
  # Prawn's flow layout cannot shape them correctly: Hebrew needs
  # right-to-left reordering -- empirically confirmed broken, rendering
  # mirrored despite full cmap coverage, not merely assumed risky -- Arabic
  # needs RTL reordering plus contextual letter joining, and Devanagari needs
  # vowel reordering and conjunct ligatures. Checked before the missing-glyph
  # check in .guard_renderable! below, so a Devanagari character -- which is
  # both uncovered and shaping-required -- is reported as the latter, not as a
  # coverage gap. Real support is tracked separately; see ADR-0024.
  SHAPING_REQUIRED_BLOCKS = %w[Hebrew Arabic Devanagari].freeze

  FONT_DIR = Rails.root.join("vendor/fonts")
  BODY_FONT = "LiberationSans".freeze
  FALLBACK_FONT = "DejaVuSans".freeze
  CJK_FONT = "NotoSansCJKsc".freeze

  FONT_FAMILIES = {
    BODY_FONT => {
      normal: FONT_DIR.join("LiberationSans-Regular.ttf").to_s,
      bold: FONT_DIR.join("LiberationSans-Bold.ttf").to_s
    },
    # Registered normal-only on purpose: Prawn's fallback always resolves to
    # the normal weight, so a bold face here would never be selected.
    FALLBACK_FONT => {
      normal: FONT_DIR.join("DejaVuSans.ttf").to_s
    },
    # Normal-only for the same reason as FALLBACK_FONT above. Simplified
    # Chinese was chosen among the single-region Noto Sans CJK variants --
    # see ADR-0024 for that choice. This file is NOT the officially
    # distributed one: Noto Sans CJK ships as CFF-outline OpenType (an "OTTO"
    # sfnt, not TrueType), and embedding that as-is reproduces issue #81's
    # exact "Missing or empty DescendantFonts entry" corruption -- the real
    # cause was the outline format, not the .ttc collection issue #81
    # suspected. This is the official Sans2.004 NotoSansCJKsc-Regular.otf
    # converted to TrueType (glyf) outlines with fonttools' otf2ttf/cu2qu, the
    # format Prawn/TTFunk's Type0/CID embedding actually supports. See
    # ADR-0024 for the verification and the size cost of the conversion, and
    # .cmap_for below for why this ~19MB file doesn't cost an ordinary
    # Latin-script resume anything.
    CJK_FONT => {
      normal: FONT_DIR.join("NotoSansCJKsc-Regular.ttf").to_s
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

  class << self
    def call(resume:)
      new(resume: resume).call
    end

    # Public so DownloadsController can refuse a request before it spends any
    # per-subject pdf_generation quota (issue #92/ADR-0025): every field this
    # walks (name, skills, original bullets, etc.) is a real Resume/Experience/
    # Education attribute that exists before any LLM call runs, so there is
    # nothing instance- or document-specific about the check. #call above
    # invokes this first too, unchanged from before this method was made
    # public and class-level -- Resume::OptimizedPdfJob's call through #call
    # is what backstops the one case the controller can't see: bullets
    # BulletRewriter has not rewritten yet.
    def guard_renderable!(resume:)
      missing_glyph_counts = Hash.new(0)
      shaping_required_counts = Hash.new(0)

      renderable_text(resume).each do |string|
        string.to_s.each_char do |char|
          next if char.match?(/\s/)

          block = unicode_block(char)

          if SHAPING_REQUIRED_BLOCKS.include?(block)
            shaping_required_counts[block] += 1
          elsif !renderable?(char)
            missing_glyph_counts[block] += 1
          end
        end
      end

      return if missing_glyph_counts.empty? && shaping_required_counts.empty?

      raise UnrenderableCharacterError.new(
        missing_glyph_counts: missing_glyph_counts,
        shaping_required_counts: shaping_required_counts
      )
    end

    private

      # Every dynamic string the render_* methods below pass to document.text.
      # The static section headers, SEPARATOR and BULLET_PREFIX are ASCII by
      # construction and formatted dates are ASCII in the default locale, so
      # only user-supplied values need checking.
      def renderable_text(resume)
        [
          resume.name, resume.email, resume.phone, resume.summary,
          *Array(resume.skills),
          *resume.experiences.flat_map { |e| [ e.company, e.title, e.location, *Array(e.bullets) ] },
          *resume.educations.flat_map { |e| [ e.school, e.degree, e.field_of_study ] }
        ].compact
      end

      def renderable?(char)
        font_paths.any? { |path| (cmap_for(path)[char.ord] || 0) != 0 }
      end

      def font_paths
        FONT_FAMILIES.values.flat_map(&:values)
      end

      # Opens and parses one font's cmap on first use, then caches it for the
      # life of the process -- not per Resume::Pdf instance, so a font already
      # consulted by an earlier render is never reparsed. Combined with
      # #renderable?'s Array#any? (short-circuits on the first font with the
      # glyph, and font_paths is FONT_FAMILIES' declaration order: Liberation,
      # DejaVu, then the CJK font), an ASCII-only resume never opens the CJK
      # file at all. Measured via TTFunk directly: ~1-6ms to parse either
      # Latin face, ~65-110ms for the ~16MB CJK face -- see ADR-0025.
      def cmap_for(path)
        @cmaps ||= {}
        @cmaps[path] ||= TTFunk::File.open(path).cmap.unicode.first
      end

      # ADR-0015: for a CJK name the codepoints ARE the name, so a log line
      # listing "U+5F35 U+5049" leaks precisely what logging the raw string
      # would. The block name plus a count is the most specific thing that is
      # safe to emit.
      def unicode_block(char)
        UNICODE_BLOCKS.find { |range, _| range.cover?(char.ord) }&.last || "an unsupported script"
      end
  end

  def initialize(resume:)
    @resume = resume
    @document = Prawn::Document.new
    @document.font_families.update(FONT_FAMILIES)
    @document.font(BODY_FONT)
    @document.fallback_fonts([ FALLBACK_FONT, CJK_FONT ])
    @document.font_size = BODY_FONT_SIZE
    @document.fill_color = BODY_COLOR
  end

  def call
    self.class.guard_renderable!(resume: resume)
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
