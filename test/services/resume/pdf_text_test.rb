require "test_helper"

class Resume::PdfTextTest < ActiveSupport::TestCase
  test "extracts text from a PDF" do
    text = Resume::PdfText.extract(sample_pdf_path)

    assert_includes text, "Jane Doe"
  end

  test "raises ExtractionError when the file doesn't exist" do
    error = assert_raises(Resume::PdfText::ExtractionError) do
      Resume::PdfText.extract("tmp/does_not_exist.pdf")
    end
    assert_match(/pdftotext exited/, error.message)
  end

  test "raises ExtractionError rather than silently falling back when pdftotext fails" do
    original_capture2 = Open3.method(:capture2)
    Open3.define_singleton_method(:capture2) do |*|
      [ "", Struct.new(:success?, :exitstatus).new(false, 1) ]
    end

    error = assert_raises(Resume::PdfText::ExtractionError) do
      Resume::PdfText.extract(sample_pdf_path)
    end
    assert_match(/pdftotext exited 1/, error.message)
  ensure
    Open3.define_singleton_method(:capture2, original_capture2)
  end

  private

  def sample_pdf_path
    @sample_pdf_path ||= begin
      path = Rails.root.join("tmp/pdf_text_test_sample_#{object_id}_#{rand(10_000)}.pdf").to_s
      Prawn::Document.generate(path) { text "Jane Doe" }
      path
    end
  end
end
