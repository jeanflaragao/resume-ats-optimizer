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

  private

  def extract_text(bytes)
    PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\n")
  end
end
