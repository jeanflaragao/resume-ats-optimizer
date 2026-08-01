require "pdf/reader"

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
# Note: reading the file's raw text here (via pdf-reader, for PDFs) to verify
# against reintroduces pdf-reader's documented layout-reliability ceiling
# (see Extractors::PdfRegex) as a verification floor under this LLM path —
# Claude's native PDF understanding can legitimately diverge from pdf-reader's
# naive text-layer reading (column order, hyphenation, bullet transcription)
# with zero hallucination involved. Expect some false-positive drops on PDFs
# from this alone; JSON files don't have this problem (same raw text on both
# sides).
class Resume::Extractors::Llm
  include WordBoundaryMatchable

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

  def self.call(file_path:, chat: LlmCallGuard.chat)
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
    {
      "name" => verified_verbatim_field(data["name"], "name"),
      "email" => verified_verbatim_field(data["email"], "email", log_value: false),
      "phone" => verified_phone(data["phone"]),
      "summary" => verified_summary(data["summary"]),
      "skills" => verified_skills(Array(data["skills"])),
      "experiences" => Array(data["experiences"]).filter_map { |experience| verified_experience(experience) },
      "educations" => Array(data["educations"]).filter_map { |education| verified_education(education) }
    }
  end

  def verified_summary(summary)
    return nil if summary.blank?

    result = fidelity_check(summary, SUMMARY_MIN_TOKEN_COVERAGE)
    return summary if result.passed

    warn_drop("summary", summary, result.unverifiable_tokens.join(", "))
    nil
  end

  def verified_skills(skills)
    skills.select do |skill|
      next true if word_boundary_match?(skill, source_text)

      warn_drop("skill", skill, "not found in source text")
      false
    end
  end

  def verified_experience(experience)
    company = experience["company"]
    title = experience["title"]

    if company.blank? || title.blank?
      warn_drop("experience entry", "company #{company.inspect} / title #{title.inspect}", "required field blank")
      return nil
    end

    unless word_boundary_match?(company.to_s, source_text) && word_boundary_match?(title.to_s, source_text)
      warn_drop("experience entry", "company #{company.inspect} / title #{title.inspect}", "not found in source text")
      return nil
    end

    experience.merge(
      "location" => verified_verbatim_field(experience["location"], "location"),
      "starts_on" => verified_year(experience["starts_on"], "starts_on"),
      "ends_on" => verified_year(experience["ends_on"], "ends_on"),
      "bullets" => verified_bullets(Array(experience["bullets"]))
    )
  end

  def verified_education(education)
    school = education["school"]

    if school.blank?
      warn_drop("education entry", "school #{school.inspect}", "required field blank")
      return nil
    end

    unless word_boundary_match?(school.to_s, source_text)
      warn_drop("education entry", "school #{school.inspect}", "not found in source text")
      return nil
    end

    education.merge(
      "starts_on" => verified_year(education["starts_on"], "starts_on"),
      "ends_on" => verified_year(education["ends_on"], "ends_on")
    )
  end

  def verified_verbatim_field(value, field_name, log_value: true)
    return value if value.blank?
    return value if word_boundary_match?(value, source_text)

    warn_drop(field_name, value, "not found in source text", log_value: log_value)
    nil
  end

  # Compared by digit content rather than a literal match, since legitimate
  # reformatting is expected (e.g. "555.123.4567" vs "(555) 123-4567").
  def verified_phone(phone)
    return phone if phone.blank?

    digits = phone.scan(DIGITS_PATTERN).join
    return phone if digits.present? && source_digits.include?(digits)

    warn_drop("phone", phone, "not found in source text", log_value: false)
    nil
  end

  def source_digits
    @source_digits ||= source_text.scan(DIGITS_PATTERN).join
  end

  def verified_year(date_value, field_name)
    return date_value if date_value.blank?

    year = date_value[YEAR_PATTERN, 1]
    return date_value if year && source_text.include?(year)

    warn_drop(field_name, date_value, "year not found in source text")
    nil
  end

  def verified_bullets(bullets)
    bullets.each_with_index.filter_map do |bullet, index|
      result = fidelity_check(bullet, BULLET_MIN_TOKEN_COVERAGE)
      next bullet if result.passed

      warn_drop("bullet #{index + 1}", bullet, result.unverifiable_tokens.join(", "))
      nil
    end
  end

  def fidelity_check(candidate_text, min_token_coverage)
    FidelityCheck.call(candidate_text: candidate_text, source_text: source_text, min_token_coverage: min_token_coverage)
  end

  def warn_drop(field, value, reason, log_value: true)
    logged_value = log_value ? value.inspect : "[redacted]"
    Rails.logger.warn("Resume::Extractors::Llm: dropped #{field} #{logged_value} (#{reason})")
  end

  def source_text
    @source_text ||= case File.extname(file_path).delete_prefix(".").downcase
    when "pdf"
      PDF::Reader.new(file_path).pages.map(&:text).join("\n")
    else
      File.read(file_path)
    end
  end
end
