# Issue #122, case 1 of the three deterministic failures that must not consume
# a credit or a resume_extraction quota slot: a scanned-image PDF with no real
# text layer. Issue #37 measured a real resume.pdf with 0 extractable
# characters -- pdftotext succeeds (it's a well-formed PDF), but there is
# nothing in it Claude could ever have extracted, so sending it to the LLM
# would only spend money to learn what this guard already knows for free.
#
# Deliberately native, not LLM-based: the presence of a text layer is a fact
# about the file, checkable with the same pdftotext call
# Resume::Extractors::Llm already needs for fidelity verification (issue #126),
# not a judgment call to delegate.
#
# Called from ResumesController#create, before Credit.available? and
# enforce_quota!(:resume_extraction) -- same relative position
# Resume::Pdf.guard_renderable! already has in DownloadsController (ADR-0025):
# a refusal knowable this early, from the file alone, must not cost anything
# downstream.
class Resume::PdfReadabilityGuard
  class UnreadableError < StandardError; end

  # ~200 characters is comfortably below any real CV (a name and one line of
  # contact info alone clears it), while a scanned image with no text layer
  # extracts to 0 -- issue #37's measured case. Not tuned finer than that: the
  # gap between "genuinely empty" and "genuinely a resume" is wide enough that
  # precision here doesn't matter.
  MIN_EXTRACTABLE_CHARACTERS = 200

  class << self
    def call!(file_path:)
      text = Resume::PdfText.extract(file_path)
      return if text.strip.length >= MIN_EXTRACTABLE_CHARACTERS

      raise UnreadableError, "extracted #{text.strip.length} characters from #{file_path}, below the #{MIN_EXTRACTABLE_CHARACTERS}-character floor"
    end
  end
end
