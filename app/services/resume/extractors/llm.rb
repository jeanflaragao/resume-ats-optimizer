# Sends the resume file directly to Claude for extraction, then verifies the
# result against the source document's own text before returning it —
# Resume::ExtractionSchema's field descriptions ask the LLM not to invent
# content, but the prompt alone isn't trusted. Anything that can't be traced
# back to the source is dropped/nulled rather than persisted, and logged so a
# drop is debuggable after the fact:
#
# - name/email/company/title/school/location/each skill: must appear verbatim
#   in the source text (WordBoundaryMatchable) — the schema treats these as
#   near-literal fields, and a coverage ratio would be the wrong tool (it's
#   order-blind, so a fabricated "Acme Corp" whose two words each appear
#   unrelated elsewhere in the document would false-pass).
# - phone: compared by its digit-only representation rather than a literal
#   match, since legitimate reformatting is expected (e.g. "555.123.4567"
#   extracted as "(555) 123-4567").
# - bullets/summary: paraphrase-tolerant token-coverage check (FidelityCheck)
#   — bullets are supposed to be close to verbatim, summary is explicitly
#   allowed to be "lightly condensed", hence the different thresholds below.
# - starts_on/ends_on: only the year is checked (legitimate reformatting is
#   expected, e.g. "Jan 2020" -> "2020-01").
#
# A failed check on company/title/school (the only AR-required fields here)
# drops the whole experience/education entry — nulling would still hit
# Resume::Import's create! and roll back the entire resume, which defeats the
# point of checking per-field at all. Everything else is dropped/nulled in
# place, keeping the rest of the entry intact.
#
# email/phone drops are logged without the raw value (field name/reason only) —
# unlike every other field, these are PII and shouldn't land verbatim in logs.
#
# Every drop below also appends a "pending item" (see #pending_item) alongside
# its existing warn_drop log line — ADR-0031: category + reason only, never the
# dropped value itself, so a fabricated field is never shown back to the user
# as something to accept. Resume::Import persists these onto the created
# Resume/Experience/Education rows so resumes/show.html.erb can surface them.
#
# Note: reading the file's raw text here (via pdftotext, for PDFs) to verify
# against still sets a verification floor under this LLM path — Claude's native
# PDF understanding can legitimately diverge from any text-layer reading (column
# order, hyphenation, bullet transcription) with zero hallucination involved.
# Expect some false-positive drops on PDFs from this alone; JSON files don't
# have this problem (same raw text on both sides). Issue #126 replaced pdf-reader
# with pdftotext specifically because pdf-reader's paint-order reading corrupted
# accented characters (a real name's diacritic landing several characters away
# from its base letter, sometimes displacing a base letter entirely) badly
# enough to fail verbatim matching on correctly-extracted, correctly-spelled
# names — not a layout ambiguity, a text-layer bug. pdftotext (poppler-utils,
# no -layout flag — see Resume::PdfText) fixed both the accent corruption and
# a two-column-interleaving word-splitting issue pdf-reader also had.
class Resume::Extractors::Llm
  include WordBoundaryMatchable
  include RedactedTokenHint

  BULLET_MIN_TOKEN_COVERAGE = 0.9
  SUMMARY_MIN_TOKEN_COVERAGE = 0.75
  YEAR_PATTERN = /\A(\d{4})/
  DIGITS_PATTERN = /\d/

  PROMPT = <<~PROMPT.freeze
    Extract the candidate's name, email, phone, professional summary, skills, work
    experience, and education from the attached document into the given schema.

    Only include information that is explicitly present in the document. Do not
    invent, infer, or embellish names, contact info, company names, job titles,
    dates, schools, or bullet points that are not literally stated. If a section or
    field is absent, omit it rather than guessing.
  PROMPT

  def self.call(file_path:, chat:)
    new(file_path: file_path, chat: chat).call
  end

  def initialize(file_path:, chat:)
    @file_path = file_path
    @chat = chat
  end

  def call
    data = chat.with_schema(Resume::ExtractionSchema).ask(PROMPT, with: file_path).content
    verify(data)
  end

  private

  attr_reader :file_path, :chat

  def verify(data)
    pending_items = []

    {
      "name" => verified_verbatim_field(data["name"], "name", pending_items),
      "email" => verified_verbatim_field(data["email"], "email", pending_items),
      "phone" => verified_phone(data["phone"], pending_items),
      "summary" => verified_summary(data["summary"], pending_items),
      "skills" => verified_skills(Array(data["skills"]), pending_items),
      "experiences" => Array(data["experiences"]).filter_map { |experience| verified_experience(experience, pending_items) },
      "educations" => Array(data["educations"]).filter_map { |education| verified_education(education, pending_items) },
      "pending_items" => pending_items
    }
  end

  def verified_summary(summary, pending_items)
    return nil if summary.blank?

    result = fidelity_check(summary, SUMMARY_MIN_TOKEN_COVERAGE)
    return summary if result.passed

    warn_drop("summary", "unverifiable tokens: #{result.unverifiable_tokens.size} tokens",
              token_info: redacted_token_hint(result.unverifiable_tokens))
    pending_items << pending_item("summary", "didn't closely match your original document")
    nil
  end

  # Aggregates all dropped skills into at most one pending item, rather than
  # one per drop -- PendingItemsController fills in a pending item by (scope,
  # field, position), and "skill" is the only field an entry can have more
  # than one drop for, so multiple identical items would be indistinguishable
  # from each other (and a fill/delete on one would remove all of them).
  def verified_skills(skills, pending_items)
    kept = skills.select do |skill|
      next true if word_boundary_match?(skill, source_text)

      warn_drop("skill", "not found in source text")
      false
    end

    dropped_count = skills.size - kept.size
    pending_items << pending_item("skill", drop_count_reason("skill", dropped_count, "didn't appear in your original document")) if dropped_count > 0

    kept
  end

  def verified_experience(experience, pending_items)
    company = experience["company"]
    title = experience["title"]

    if company.blank? || title.blank?
      warn_drop("experience entry", "required field blank")
      pending_items << pending_item("experience", "an experience entry couldn't be verified")
      return nil
    end

    unless word_boundary_match?(company.to_s, source_text) && word_boundary_match?(title.to_s, source_text)
      warn_drop("experience entry", "not found in source text")
      pending_items << pending_item("experience", "an experience entry didn't appear in your original document")
      return nil
    end

    entry_pending_items = []
    experience.merge(
      "location" => verified_verbatim_field(experience["location"], "location", entry_pending_items),
      "starts_on" => verified_year(experience["starts_on"], "starts_on", entry_pending_items),
      "ends_on" => verified_year(experience["ends_on"], "ends_on", entry_pending_items),
      "bullets" => verified_bullets(Array(experience["bullets"]), entry_pending_items),
      "pending_items" => entry_pending_items
    )
  end

  def verified_education(education, pending_items)
    school = education["school"]

    if school.blank?
      warn_drop("education entry", "required field blank")
      pending_items << pending_item("education", "an education entry couldn't be verified")
      return nil
    end

    unless word_boundary_match?(school.to_s, source_text)
      warn_drop("education entry", "not found in source text")
      pending_items << pending_item("education", "an education entry didn't appear in your original document")
      return nil
    end

    entry_pending_items = []
    education.merge(
      "starts_on" => verified_year(education["starts_on"], "starts_on", entry_pending_items),
      "ends_on" => verified_year(education["ends_on"], "ends_on", entry_pending_items),
      "pending_items" => entry_pending_items
    )
  end

  def verified_verbatim_field(value, field_name, pending_items)
    return value if value.blank?
    return value if word_boundary_match?(value, source_text)

    warn_drop(field_name, "not found in source text")
    pending_items << pending_item(field_name, "didn't appear in your original document")
    nil
  end

  # Compared by digit content rather than a literal match, since legitimate
  # reformatting is expected (e.g. "555.123.4567" vs "(555) 123-4567").
  def verified_phone(phone, pending_items)
    return phone if phone.blank?

    digits = phone.scan(DIGITS_PATTERN).join
    return phone if digits.present? && source_digits.include?(digits)

    warn_drop("phone", "not found in source text")
    pending_items << pending_item("phone", "didn't appear in your original document")
    nil
  end

  def source_digits
    @source_digits ||= source_text.scan(DIGITS_PATTERN).join
  end

  def verified_year(date_value, field_name, pending_items)
    return date_value if date_value.blank?

    year = date_value[YEAR_PATTERN, 1]
    return date_value if year && source_text.include?(year)

    warn_drop(field_name, "year not found in source text")
    pending_items << pending_item(field_name, "date didn't appear in your original document")
    nil
  end

  # Aggregated into at most one pending item per experience, same reasoning as
  # verified_skills above.
  def verified_bullets(bullets, pending_items)
    kept = bullets.each_with_index.filter_map do |bullet, index|
      result = fidelity_check(bullet, BULLET_MIN_TOKEN_COVERAGE)
      next bullet if result.passed

      warn_drop("bullet #{index + 1}", "unverifiable tokens: #{result.unverifiable_tokens.size} tokens",
                token_info: redacted_token_hint(result.unverifiable_tokens))
      nil
    end

    dropped_count = bullets.size - kept.size
    pending_items << pending_item("bullet", drop_count_reason("bullet", dropped_count, "didn't closely match your original document")) if dropped_count > 0

    kept
  end

  def fidelity_check(candidate_text, min_token_coverage)
    FidelityCheck.call(candidate_text: candidate_text, source_text: source_text, min_token_coverage: min_token_coverage)
  end

  def drop_count_reason(noun, count, tail)
    subject = count == 1 ? "a #{noun}" : "#{count} #{noun.pluralize}"
    "#{subject} #{tail}"
  end

  def warn_drop(field, reason, token_info: nil)
    token_hint = token_info.present? ? " [#{token_info}]" : ""
    Rails.logger.warn("Resume::Extractors::Llm: dropped #{field} (#{reason})#{token_hint}")
  end

  # kind is always "dropped_field" here (as opposed to Resume::Import's own
  # "unparsed_date" kind) — every drop in this class is a possibly-fabricated
  # value, never a parse failure, so raw_value is always nil by construction.
  # See ADR-0031: that's what makes "never prefill a dropped value" a provable
  # property of the data rather than a discipline every call site has to
  # remember.
  def pending_item(field, reason)
    { "kind" => "dropped_field", "field" => field, "reason" => reason, "raw_value" => nil }
  end

  # Issue #122: the pdftotext call itself moved to Resume::PdfText, shared
  # with Resume::PdfReadabilityGuard's upload-time check, so both read the
  # exact same extraction rather than two call sites drifting.
  def source_text
    @source_text ||= case File.extname(file_path).delete_prefix(".").downcase
    when "pdf"
      Resume::PdfText.extract(file_path)
    else
      File.read(file_path)
    end
  end
end
