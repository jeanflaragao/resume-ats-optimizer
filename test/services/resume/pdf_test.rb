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
  # render as blank .notdef glyphs -- see the guard test below for why.
  UNSUPPORTED_SCRIPTS = {
    "CJK" => "張偉",
    "emoji" => "Shipped 🚀 to prod"
  }.freeze

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

      assert_raises(Resume::Pdf::UnrenderableCharacterError) do
        Resume::Pdf.call(resume: resume)
      end
    end
  end

  # A missing glyph does NOT raise in Prawn -- it renders .notdef (nothing
  # visible) while the ToUnicode CMap still extracts the original text. So a
  # CJK resume would download "successfully" with a blank name line and parse
  # cleanly in an ATS. Silently shipping that is worse than failing, which is
  # why the guard exists at all; this test pins the behaviour it prevents.
  test "the guard fires instead of producing a PDF whose text extracts but does not display" do
    resume = Resume.new(name: "Alex Doe", summary: "張偉")

    error = assert_raises(Resume::Pdf::UnrenderableCharacterError) do
      Resume::Pdf.call(resume: resume)
    end

    assert_match(/CJK/, error.message)
    assert_match(/\b2\b/, error.message)
  end

  # ADR-0015: for a CJK name the codepoints ARE the name, so logging "U+5F35"
  # leaks exactly what logging the string would. The error message is written
  # to the log by Resume::OptimizedPdfJob, so it must carry the Unicode block
  # name and a count and nothing else.
  test "the unrenderable-character error names the Unicode block without leaking the characters" do
    resume = Resume.new(name: "Alex Doe", summary: "張偉")

    error = assert_raises(Resume::Pdf::UnrenderableCharacterError) do
      Resume::Pdf.call(resume: resume)
    end

    assert_not_includes error.message, "張"
    assert_not_includes error.message, "偉"
    assert_not_includes error.message, "5F35"
    assert_not_includes error.message, "U+"
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
