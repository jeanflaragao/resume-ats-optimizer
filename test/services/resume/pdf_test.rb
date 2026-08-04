require "test_helper"
require "pdf/reader"

class Resume::PdfTest < ActiveSupport::TestCase
  test "renders name, contact info, summary, experience, education, and skills" do
    resume = resumes(:one)

    bytes = Resume::Pdf.call(resume: resume)
    assert bytes.start_with?("%PDF")

    text = extract_text(bytes)
    assert_includes text, resume.name
    assert_includes text, resume.email
    assert_includes text, resume.phone
    assert_includes text, resume.summary
    assert_includes text, "Skills"
    assert_includes text, "Ruby"

    resume.experiences.each do |experience|
      assert_includes text, experience.company
      Array(experience.bullets).each { |bullet| assert_includes text, bullet }
    end

    resume.educations.each { |education| assert_includes text, education.school }
  end

  test "omits the header block entirely when name, email, and phone are all blank" do
    resume = Resume.new(summary: "Just a summary, no contact info.")

    text = extract_text(Resume::Pdf.call(resume: resume))

    assert text.strip.start_with?("Summary")
  end

  test "renders a contact line from whichever of email/phone is present, with no name line" do
    resume = Resume.new(phone: "555-000-1111")

    text = extract_text(Resume::Pdf.call(resume: resume))

    assert_includes text, "555-000-1111"
  end

  test "omits summary, experience, education, and skills sections when blank" do
    resume = Resume.new(name: "Alex Doe")

    text = extract_text(Resume::Pdf.call(resume: resume))

    assert_includes text, "Alex Doe"
    refute_includes text, "Summary"
    refute_includes text, "Experience"
    refute_includes text, "Education"
    refute_includes text, "Skills"
  end

  test "renders an experience entry with no bullets without raising" do
    resume = Resume.new(name: "Alex Doe")
    resume.experiences.build(company: "Acme", title: "Engineer", bullets: [], position: 1)

    text = extract_text(Resume::Pdf.call(resume: resume))

    assert_includes text, "Acme"
    assert_includes text, "Engineer"
  end

  test "starts a new page once content overflows the first one" do
    resume = Resume.new(name: "Alex Doe")
    30.times do |i|
      resume.experiences.build(
        company: "Company #{i}",
        title: "Engineer",
        bullets: [ "Did something notable", "Did something else notable" ],
        position: i
      )
    end

    reader = PDF::Reader.new(StringIO.new(Resume::Pdf.call(resume: resume)))

    assert_operator reader.page_count, :>, 1
  end

  # Reproduction table from issue #74, verbatim. Every string below except the
  # last two crashed the download job before the embedded font landed --
  # Prawn's built-in AFM fonts are Windows-1252 only, so the boundary was never
  # "ASCII vs. not": the bullet, em dash, curly quotes, en dash and Latin-1
  # accents in ALREADY_RENDERED all sat inside Windows-1252 and always worked,
  # which is why this went unnoticed for so long.
  ALREADY_RENDERED = {
    "an ASCII baseline" => "Senior Software Engineer",
    "the bullet prefix" => "•  Led the migration",
    "an em dash and curly quotes" => "Led — the “growth” team",
    "Latin-1 accents" => "José Müller — Café Niño",
    "an en dash in a date range" => "2020 – 2024"
  }.freeze

  PREVIOUSLY_CRASHED = {
    "Polish" => "Wojciech Bałka, Ślusarski",
    "Czech" => "Jiří Novák, Plžeň",
    "Turkish" => "Gülşah İsmail",
    "Hungarian" => "Gergő Török",
    "Romanian" => "Andrei Popescu, Iași",
    "Cyrillic" => "Анна Иванова",
    "Greek" => "Γιώργος",
    "an arrow" => "Revenue → 2x YoY",
    "a checkmark" => "✓ Shipped on time",
    "a non-breaking hyphen" => "re‑architected the API"
  }.freeze

  # No font we ship covers these. They must raise a named error rather than
  # render as blank .notdef glyphs -- see the guard test below for why. CJK
  # used to be here too (issue #81) -- ADR-0024's Noto Sans CJK fallback moved
  # it to CJK_NOW_RENDERS below.
  UNSUPPORTED_SCRIPTS = {
    "emoji" => "Shipped 🚀 to prod"
  }.freeze

  # Full glyph coverage in DejaVu Sans (Hebrew) or genuinely no coverage
  # anywhere (Devanagari) -- refused anyway, because Prawn's flow layout does
  # no bidi reordering or contextual letter joining. ADR-0024. Non-vacuity:
  # before that ADR's SHAPING_REQUIRED_BLOCKS existed, Hebrew and Arabic both
  # passed this guard and rendered silently wrong -- confirmed by running
  # these two cases against the pre-fix code (see the PR body for the
  # captured failure output).
  SHAPING_REFUSED = {
    "Hebrew" => "שלום",
    "Arabic" => "مرحبا",
    "Devanagari" => "राम"
  }.freeze

  CJK_NOW_RENDERS = { "CJK" => "張偉" }.freeze

  (ALREADY_RENDERED.merge(PREVIOUSLY_CRASHED)).each do |label, string|
    test "renders #{label} and extracts it back verbatim" do
      resume = Resume.new(name: "Alex Doe", summary: string)

      assert_extracts string, from: Resume::Pdf.call(resume: resume)
    end
  end

  test "renders a very long unbroken token without raising" do
    resume = Resume.new(name: "Alex Doe", summary: "a" * 4000)

    assert Resume::Pdf.call(resume: resume).start_with?("%PDF")
  end

  UNSUPPORTED_SCRIPTS.each do |label, string|
    test "raises rather than silently rendering blanks for #{label}" do
      resume = Resume.new(name: "Alex Doe", summary: string)

      error = assert_raises(Resume::Pdf::UnrenderableCharacterError) do
        Resume::Pdf.call(resume: resume)
      end

      assert_includes error.missing_glyph_blocks, "Emoji and Pictographs"
      assert_empty error.shaping_required_blocks
    end
  end

  SHAPING_REFUSED.each do |block, string|
    test "refuses #{block} even though it has no missing-glyph coverage gap for the parts that do" do
      resume = Resume.new(name: "Alex Doe", summary: string)

      error = assert_raises(Resume::Pdf::UnrenderableCharacterError) do
        Resume::Pdf.call(resume: resume)
      end

      assert_includes error.shaping_required_blocks, block
      assert_not_includes error.missing_glyph_blocks, block
      assert_match(/requires? text shaping/, error.message)
    end
  end

  # Issue #81: adding a font is not enough to prove a name renders -- Prawn
  # extracts text via the ToUnicode CMap even for a glyph it drew as an
  # invisible .notdef, so extraction succeeding is not proof of visible
  # rendering. Check glyph presence directly against the vendored font file,
  # not just that Resume::Pdf.call doesn't raise and extraction round-trips.
  CJK_NOW_RENDERS.each do |label, string|
    test "renders #{label} instead of refusing it, now that a CJK font is embedded" do
      resume = Resume.new(name: "Alex Doe", summary: string)

      assert_extracts string, from: Resume::Pdf.call(resume: resume)
    end

    test "the vendored CJK font actually has glyphs for #{label}, not just a declared cmap entry" do
      cmap = TTFunk::File.open(Resume::Pdf::FONT_FAMILIES[Resume::Pdf::CJK_FONT][:normal]).cmap.unicode.first

      string.each_char do |char|
        assert (cmap[char.ord] || 0) != 0, "expected #{Resume::Pdf::CJK_FONT} to cover U+#{char.ord.to_s(16).upcase}"
      end
    end
  end

  # A missing glyph does NOT raise in Prawn -- it renders .notdef (nothing
  # visible) while the ToUnicode CMap still extracts the original text. So a
  # resume with an uncovered script would download "successfully" with a
  # blank line and parse cleanly in an ATS. Silently shipping that is worse
  # than failing, which is why the guard exists at all; this test pins the
  # behaviour it prevents. Uses emoji, not CJK, now that CJK is covered.
  test "the guard fires instead of producing a PDF whose text extracts but does not display" do
    resume = Resume.new(name: "Alex Doe", summary: "Shipped 🚀 to prod")

    error = assert_raises(Resume::Pdf::UnrenderableCharacterError) do
      Resume::Pdf.call(resume: resume)
    end

    assert_match(/Emoji/, error.message)
    assert_match(/\b1\b/, error.message)
  end

  # ADR-0015: for a CJK name the codepoints ARE the name, so logging "U+5F35"
  # leaks exactly what logging the string would. The error message is written
  # to the log by Resume::OptimizedPdfJob and DownloadsController, so it must
  # carry the Unicode block name and a count and nothing else -- true for
  # both refusal reasons, not just the missing-glyph one.
  test "the unrenderable-character error names the Unicode block without leaking the characters" do
    resume = Resume.new(name: "Alex Doe", summary: "Shipped 🚀 to prod")

    error = assert_raises(Resume::Pdf::UnrenderableCharacterError) do
      Resume::Pdf.call(resume: resume)
    end

    assert_not_includes error.message, "🚀"
    assert_not_includes error.message, "1F680"
    assert_not_includes error.message, "U+"
  end

  test "a shaping-required refusal names the Unicode block without leaking the characters" do
    resume = Resume.new(name: "Alex Doe", summary: "שלום")

    error = assert_raises(Resume::Pdf::UnrenderableCharacterError) do
      Resume::Pdf.call(resume: resume)
    end

    assert_not_includes error.message, "שלום"
    assert_not_includes error.message, "U+"
  end

  # ADR-0025: font_cmaps resolves lazily, in FONT_FAMILIES declaration order,
  # cached at the class level. An all-ASCII resume must never open the ~19MB
  # CJK font -- confirmed regression risk, not hypothetical (see ADR-0025's
  # benchmark table). Reset the class-level cache first: other tests in this
  # process may already have opened the CJK font, which would make this test
  # pass for the wrong reason.
  test "an all-ASCII resume never opens the CJK fallback font" do
    Resume::Pdf.instance_variable_set(:@cmaps, {})
    resume = Resume.new(name: "Alex Doe", email: "alex@example.com", summary: "Plain ASCII summary.")

    Resume::Pdf.call(resume: resume)

    opened_paths = Resume::Pdf.instance_variable_get(:@cmaps).keys
    assert opened_paths.any? { |path| path.include?("LiberationSans") }
    assert_not opened_paths.any? { |path| path.include?("NotoSansCJK") }
  ensure
    Resume::Pdf.instance_variable_set(:@cmaps, {})
  end

  # ADR-0004 chose this template for ATS-friendliness, and text extraction is
  # the whole point. Embedding a subset font only helps if Prawn emits a
  # ToUnicode CMap with it -- assert on a real name rather than trusting that.
  test "a non-Latin name survives a round trip through PDF text extraction" do
    resume = Resume.new(name: "Анна Иванова", email: "anna@example.com")
    resume.experiences.build(company: "Bałka Sp. z o.o.", title: "Инженер", bullets: [], position: 0)

    text = extract_text(Resume::Pdf.call(resume: resume))

    assert_includes text, "Анна Иванова"
    assert_includes text, "Bałka Sp. z o.o."
    assert_includes text, "Инженер"
  end

  # Liberation Sans is metric-compatible with Helvetica, so swapping the font
  # must not reflow anything. A font that measures differently would silently
  # push one-page resumes onto a second page.
  test "the embedded font keeps Helvetica's metrics so the layout does not move" do
    sample = "Led the migration of a monolithic Rails application to a service-oriented architecture."
    # This is the only place the built-in AFM fonts are still touched, purely as
    # the metric baseline to compare against -- silence Prawn's m17n banner.
    Prawn::Fonts::AFM.hide_m17n_warning = true
    afm = Prawn::Document.new.width_of(sample, size: Resume::Pdf::BODY_FONT_SIZE)

    embedded = Prawn::Document.new
    embedded.font_families.update(Resume::Pdf::FONT_FAMILIES)
    embedded.font(Resume::Pdf::BODY_FONT)
    actual = embedded.width_of(sample, size: Resume::Pdf::BODY_FONT_SIZE)

    assert_in_delta afm, actual, afm * 0.01
  end

  private

  def extract_text(bytes)
    PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\n")
  end

  # PDF text extraction collapses runs of positioned whitespace, so the two
  # spaces in BULLET_PREFIX come back as one. That is not a font property --
  # the built-in AFM fonts collapse it identically -- so comparing on
  # whitespace-normalized text keeps these assertions about the characters
  # actually rendering, which is what issue #74 is about.
  def assert_extracts(expected, from:)
    normalize = ->(string) { string.gsub(/\s+/, " ").strip }

    assert_includes normalize.call(extract_text(from)), normalize.call(expected)
  end
end
