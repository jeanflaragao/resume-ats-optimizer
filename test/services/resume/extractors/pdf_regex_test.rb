require "test_helper"
require "prawn"

class Resume::Extractors::PdfRegexTest < ActiveSupport::TestCase
  test "extracts summary, skills, experiences, and educations from a LinkedIn-style layout" do
    result = Resume::Extractors::PdfRegex.call(file_path: sample_pdf_path)

    assert_equal "Senior backend engineer with 8 years of experience.", result["summary"]
    assert_equal [ "Ruby", "Rails", "PostgreSQL" ], result["skills"]

    assert_equal 2, result["experiences"].size
    most_recent, earlier = result["experiences"]

    assert_equal "Acme Corp", most_recent["company"]
    assert_equal "Senior Engineer", most_recent["title"]
    assert_equal "Jan 2020", most_recent["starts_on"]
    assert_nil most_recent["ends_on"]
    assert_equal [ "Led migration to microservices", "Mentored three junior engineers" ], most_recent["bullets"]

    assert_equal "Globex", earlier["company"]
    assert_equal "Jan 2016", earlier["starts_on"]
    assert_equal "Dec 2019", earlier["ends_on"]

    assert_equal 1, result["educations"].size
    assert_equal "State University", result["educations"].first["school"]
    assert_equal "B.S. Computer Science", result["educations"].first["degree"]
  end

  test "returns empty collections when a section is absent" do
    path = Rails.root.join("tmp/pdf_regex_test_no_sections.pdf").to_s
    Prawn::Document.generate(path) { text "Just a name, no sections." }

    result = Resume::Extractors::PdfRegex.call(file_path: path)

    assert_nil result["summary"]
    assert_equal [], result["skills"]
    assert_equal [], result["experiences"]
    assert_equal [], result["educations"]
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  private

  def sample_pdf_path
    @sample_pdf_path ||= begin
      path = Rails.root.join("tmp/pdf_regex_test_sample.pdf").to_s
      Prawn::Document.generate(path) do
        text "Jane Doe", size: 20
        text "Summary"
        text "Senior backend engineer with 8 years of experience."
        text "Experience"
        text "Senior Engineer"
        text "Acme Corp"
        text "Jan 2020 - Present"
        text "• Led migration to microservices"
        text "• Mentored three junior engineers"
        text "Software Engineer"
        text "Globex"
        text "Jan 2016 - Dec 2019"
        text "Education"
        text "State University"
        text "B.S. Computer Science"
        text "Skills"
        text "Ruby, Rails, PostgreSQL"
      end
      path
    end
  end
end
