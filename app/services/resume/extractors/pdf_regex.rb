require "pdf/reader"

# Best-effort, deterministic alternative to Resume::Extractors::Llm. Works well on
# LinkedIn's fairly consistent "Save to PDF" profile export; accuracy degrades
# on free-form personal resumes since there's no fixed layout to pattern-match.
class Resume::Extractors::PdfRegex
  SECTION_PATTERNS = {
    summary: /\A(summary|about|profile)\b/i,
    experience: /\A(experience|work experience|employment( history)?)\b/i,
    education: /\Aeducation\b/i,
    skills: /\A(skills|technical skills)\b/i
  }.freeze

  DATE_RANGE = /
    (?<start>[A-Za-z]{3,9}\.?\s+\d{4}|\d{4})
    \s*(-|–|—|to)\s*
    (?<end>[A-Za-z]{3,9}\.?\s+\d{4}|\d{4}|Present|Current)
  /ix

  BULLET_PREFIX = /\A[•●▪\-\*]\s*/

  def self.call(file_path:)
    new(file_path).call
  end

  def initialize(file_path)
    @lines = extract_lines(file_path)
  end

  def call
    sections = split_into_sections

    {
      "summary" => sections[:summary].join(" ").strip.presence,
      "skills" => extract_skills(sections[:skills]),
      "experiences" => extract_entries(sections[:experience], :experience),
      "educations" => extract_entries(sections[:education], :education)
    }
  end

  private

  def extract_lines(file_path)
    text = PDF::Reader.new(file_path).pages.map(&:text).join("\n")
    text.split("\n").map(&:strip).reject(&:empty?)
  end

  def split_into_sections
    sections = Hash.new { |hash, key| hash[key] = [] }
    current_section = nil

    @lines.each do |line|
      matched = SECTION_PATTERNS.find { |_, pattern| pattern.match?(line) }
      if matched
        current_section = matched.first
      elsif current_section
        sections[current_section] << line
      end
    end

    sections
  end

  def extract_skills(lines)
    lines.flat_map { |line| line.split(/[,|]|\s{2,}/) }
         .map { |skill| skill.sub(BULLET_PREFIX, "").strip }
         .reject(&:blank?)
  end

  # State machine over the section's lines: lines before a date-range line are
  # the entry's header (title/company/location or school/degree/field); the
  # date line itself is parsed for start/end dates; lines after it that look
  # like bullets belong to this entry, and the first non-bullet line starts
  # the next entry's header.
  def extract_entries(lines, kind)
    entries = []
    header = []
    date_line = nil
    bullets = []
    in_bullets = false

    finalize = lambda do
      entries << build_entry(header, date_line, bullets, kind) if header.any?
      header = []
      date_line = nil
      bullets = []
      in_bullets = false
    end

    lines.each do |line|
      if !in_bullets && DATE_RANGE.match?(line)
        date_line = line
        in_bullets = true
      elsif in_bullets && bullet_line?(line)
        bullets << line.sub(BULLET_PREFIX, "").strip
      elsif in_bullets
        finalize.call
        header << line
      else
        header << line
      end
    end
    finalize.call

    entries
  end

  def bullet_line?(line)
    BULLET_PREFIX.match?(line)
  end

  def build_entry(header, date_line, bullets, kind)
    starts_on, ends_on = parse_date_range(date_line)

    if kind == :experience
      {
        "company" => header[1],
        "title" => header[0],
        "location" => header[2..]&.join(", ").presence,
        "starts_on" => starts_on,
        "ends_on" => ends_on,
        "bullets" => bullets
      }
    else
      {
        "school" => header[0],
        "degree" => header[1],
        "field_of_study" => header[2..]&.join(", ").presence,
        "starts_on" => starts_on,
        "ends_on" => ends_on
      }
    end
  end

  def parse_date_range(line)
    match = DATE_RANGE.match(line)
    return [ nil, nil ] unless match

    ends_on = match[:end]
    ends_on = nil if ends_on&.match?(/\A(present|current)\z/i)
    [ match[:start], ends_on ]
  end
end
