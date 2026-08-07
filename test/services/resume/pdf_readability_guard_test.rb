require "test_helper"

class Resume::PdfReadabilityGuardTest < ActiveSupport::TestCase
  test "passes silently for a PDF with a real text layer" do
    assert_nil Resume::PdfReadabilityGuard.call!(file_path: readable_pdf_path)
  end

  # Issue #37's measured case: a scanned-image PDF with no text layer extracts
  # to 0 characters -- pdftotext succeeds (it's a well-formed PDF), so this has
  # to be a length check on the result, not a pdftotext failure.
  test "raises UnreadableError for a PDF with no extractable text" do
    error = assert_raises(Resume::PdfReadabilityGuard::UnreadableError) do
      Resume::PdfReadabilityGuard.call!(file_path: blank_pdf_path)
    end
    assert_match(/0 characters/, error.message)
  end

  # Swaps Resume::PdfText.extract's return value to a string of an exact,
  # controlled length -- a real Prawn-generated PDF can't pin this precisely,
  # since word-wrapping a long unbroken string introduces a pdftotext-visible
  # line break of its own, off-by-one against the input length. The two tests
  # above already cover the real pdftotext round-trip; these two isolate the
  # guard's own boundary arithmetic. Same singleton-method-swap technique
  # test/services/resume/pdf_text_test.rb uses for Open3.capture2, since this
  # Minitest version has no Object#stub (no minitest/mock).
  test "raises UnreadableError for text just under the floor" do
    with_extracted_text("a" * (Resume::PdfReadabilityGuard::MIN_EXTRACTABLE_CHARACTERS - 1)) do
      assert_raises(Resume::PdfReadabilityGuard::UnreadableError) do
        Resume::PdfReadabilityGuard.call!(file_path: "irrelevant.pdf")
      end
    end
  end

  test "passes for text right at the floor" do
    with_extracted_text("a" * Resume::PdfReadabilityGuard::MIN_EXTRACTABLE_CHARACTERS) do
      assert_nil Resume::PdfReadabilityGuard.call!(file_path: "irrelevant.pdf")
    end
  end

  private

  def with_extracted_text(text)
    original_extract = Resume::PdfText.method(:extract)
    Resume::PdfText.define_singleton_method(:extract) { |*| text }
    yield
  ensure
    Resume::PdfText.define_singleton_method(:extract, original_extract)
  end

  def readable_pdf_path
    path = Rails.root.join("tmp/pdf_readability_guard_test_readable_#{object_id}_#{rand(10_000)}.pdf").to_s
    Prawn::Document.generate(path) do
      text "Jane Doe"
      text "jane@example.com"
      text "555-123-4567"
      text "Summary"
      text "Product-minded engineer with a long track record of shipping reliable, scalable systems on time and mentoring the engineers around her."
      text "Experience"
      text "Senior Engineer, Acme Corp, Jan 2020 - Present"
      text "Led migration to microservices. Mentored three junior engineers."
    end
    path
  end

  def blank_pdf_path
    @blank_pdf_path ||= begin
      path = Rails.root.join("tmp/pdf_readability_guard_test_blank_#{object_id}_#{rand(10_000)}.pdf").to_s
      Prawn::Document.generate(path) { }
      path
    end
  end
end
