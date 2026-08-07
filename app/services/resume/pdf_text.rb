require "open3"

# The single pdftotext choke point (issue #126) -- shared by
# Resume::Extractors::Llm's fidelity-check verification and
# Resume::PdfReadabilityGuard's upload-time readability check (issue #122),
# so both read the exact same extraction rather than two call sites drifting.
# It runs twice per PDF upload as a result (once for the guard, once for
# verification) -- accepted deliberately: it's a fast local subprocess, not an
# LLM call, and threading a precomputed value through Resume::Import's
# signature isn't worth the extra surface area for this.
class Resume::PdfText
  # The pdftotext-specific counterpart to PDF::Reader::MalformedPDFError,
  # which ResumesController's rescue clause already maps to the same friendly
  # "we couldn't read that file" flash. PdfRegex (a different extractor) still
  # uses pdf-reader directly and can still raise the original PDF::Reader
  # errors, so those stay in that rescue list too -- this is additive, not a
  # replacement.
  class ExtractionError < StandardError; end

  class << self
    # No -layout flag, deliberately: -layout preserves the PDF's column
    # positions, which reintroduces the same class of corruption pdftotext was
    # chosen to fix, just from a different cause -- a two-column resume read
    # row-by-row interleaves both columns onto one output line, splitting a
    # word across the seam ("Ja-" / "nuary" from "January", straddling the
    # column break). Default mode reads one column fully before the next,
    # matching normal reading order and keeping words intact. Verified both
    # modes directly against a real two-column CV before choosing this over
    # -layout (issue #126).
    #
    # Raises rather than falling back to a worse extraction on failure --
    # poppler-utils is a required package in both Dockerfiles and CI; a
    # missing binary or a pdftotext failure is a deploy/environment bug that
    # should be loud, not a reason to silently reintroduce the corruption this
    # method exists to avoid.
    def extract(file_path)
      stdout, status = Open3.capture2("pdftotext", file_path, "-")
      raise ExtractionError, "pdftotext exited #{status.exitstatus} extracting #{file_path}" unless status.success?

      stdout
    end
  end
end
