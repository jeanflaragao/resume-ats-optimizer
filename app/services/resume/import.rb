# Entry point for turning an uploaded LinkedIn export or personal resume into
# a persisted Resume. Wraps everything in a transaction: if the extracted data
# can't satisfy Experience/Education validations (e.g. a regex parse that
# couldn't find a company name), the whole import rolls back and raises
# rather than silently persisting partial/garbage data.
class Resume::Import
  class UnsupportedFormatError < StandardError; end

  STRATEGIES = {
    "llm" => { "pdf" => Resume::Extractors::Llm, "json" => Resume::Extractors::Llm },
    "regex" => { "pdf" => Resume::Extractors::PdfRegex, "json" => Resume::Extractors::JsonMapper }
  }.freeze

  # parse_date's return: `date` is nil whenever there was nothing to parse OR
  # parsing failed -- `raw_value` is the one signal that distinguishes "blank"
  # from "failed", set only when the rescue below actually fires. That's what
  # lets persist build a pending item with the original string a user can
  # correct, without also flagging every ordinary blank/"present" date.
  DateParseResult = Data.define(:date, :raw_value)

  UNPARSED_DATE_REASON = "not recognized as a date"

  def self.call(file:, strategy:, chat: LlmCallGuard.chat)
    new(file: file, strategy: strategy, chat: chat).call
  end

  def initialize(file:, strategy:, chat:)
    @file = file
    @strategy = strategy
    @chat = chat
  end

  def call
    data = extractor == Resume::Extractors::Llm ? extractor.call(file_path: path, chat: chat) : extractor.call(file_path: path)
    persist(data)
  end

  private

  attr_reader :file, :strategy, :chat

  def extractor
    @extractor ||= begin
      strategies = STRATEGIES[strategy] or raise UnsupportedFormatError, "Unknown strategy: #{strategy.inspect}"
      strategies[format] or raise UnsupportedFormatError, "No #{strategy} extractor for .#{format} files"
    end
  end

  def format
    File.extname(filename).delete_prefix(".").downcase
  end

  def filename
    file.respond_to?(:original_filename) ? file.original_filename : path
  end

  def path
    file.respond_to?(:path) ? file.path.to_s : file.to_s
  end

  def source
    extractor.name.demodulize.underscore
  end

  def persist(data)
    Resume.transaction do
      resume = Resume.create!(
        name: data["name"],
        email: data["email"],
        phone: data["phone"],
        summary: data["summary"],
        skills: Array(data["skills"]),
        source: source,
        pending_items: Array(data["pending_items"])
      )

      Array(data["experiences"]).each_with_index do |experience, index|
        starts_on = parse_date(experience["starts_on"])
        ends_on = parse_date(experience["ends_on"])

        resume.experiences.create!(
          company: experience["company"],
          title: experience["title"],
          location: experience["location"],
          starts_on: starts_on.date,
          ends_on: ends_on.date,
          bullets: Array(experience["bullets"]),
          position: index,
          pending_items: Array(experience["pending_items"]) + unparsed_date_items(starts_on, ends_on)
        )
      end

      Array(data["educations"]).each_with_index do |education, index|
        starts_on = parse_date(education["starts_on"])
        ends_on = parse_date(education["ends_on"])

        resume.educations.create!(
          school: education["school"],
          degree: education["degree"],
          field_of_study: education["field_of_study"],
          starts_on: starts_on.date,
          ends_on: ends_on.date,
          position: index,
          pending_items: Array(education["pending_items"]) + unparsed_date_items(starts_on, ends_on)
        )
      end

      resume
    end
  end

  # Date.parse can't handle bare "YYYY" or "YYYY-MM" (both valid per
  # Resume::ExtractionSchema's description and common on resumes that only give a
  # year for education dates), so those are handled explicitly before falling
  # back to Date.parse for everything else (including "Jan 2020"-style text).
  def parse_date(value)
    return DateParseResult.new(date: nil, raw_value: nil) if value.blank?
    return DateParseResult.new(date: nil, raw_value: nil) if value.match?(/\A(present|current)\z/i)

    date = case value
    when /\A(\d{4})-(\d{2})\z/
      Date.new($1.to_i, $2.to_i, 1)
    when /\A\d{4}\z/
      Date.new(value.to_i, 1, 1)
    else
      Date.parse(value)
    end
    DateParseResult.new(date: date, raw_value: nil)
  rescue ArgumentError, TypeError
    DateParseResult.new(date: nil, raw_value: value)
  end

  def unparsed_date_items(starts_on, ends_on)
    [ [ "starts_on", starts_on ], [ "ends_on", ends_on ] ].filter_map do |field, result|
      next if result.raw_value.nil?

      { "kind" => "unparsed_date", "field" => field, "reason" => UNPARSED_DATE_REASON, "raw_value" => result.raw_value }
    end
  end
end
