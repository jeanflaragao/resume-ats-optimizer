class JobDescription::Extractor
  INSTRUCTIONS = <<~PROMPT.freeze
    Extract the key requirements and keywords an Applicant Tracking System would
    match against from the job description below, into the given schema.

    Only include requirements and keywords explicitly stated or clearly implied by
    the posting. Do not invent skills, qualifications, or responsibilities that
    aren't mentioned.
  PROMPT

  # The contract callers get, whatever the model returns: every field the schema
  # can produce, with the value that means "the posting didn't say". Callers
  # iterate these lists (Comparison, and the views reading the newer fields), so
  # a key that is sometimes absent is a NoMethodError waiting on the first
  # posting that omits a section. Kept in step with JobDescription::
  # ExtractionSchema by a test, since the two files drift silently otherwise.
  EMPTY_RESULT = {
    "title" => nil,
    "seniority_level" => nil,
    "years_experience_min" => nil,
    "required_skills" => [],
    "preferred_skills" => [],
    "keywords" => [],
    "responsibilities" => [],
    "education_requirements" => [],
    "soft_skills" => []
  }.freeze

  def self.call(text:, user: nil, chat: LlmCallGuard.chat(subject: user&.id&.to_s))
    # Nothing to extract, so the request would spend real money and a slot
    # against LlmCallGuard's daily cap to be told exactly this.
    return EMPTY_RESULT.dup if text.blank?

    response = chat.with_schema(JobDescription::ExtractionSchema).ask("#{INSTRUCTIONS}\nJob description:\n#{text}")
    normalize(response.content)
  end

  # A null and an absent key both mean "not stated" — the schema marks title and
  # years_experience_min optional precisely so the model can say so — and both
  # have to land on the same value here.
  def self.normalize(content)
    attributes = content.to_h
    EMPTY_RESULT.to_h { |key, default| [ key, attributes[key].nil? ? default : attributes[key] ] }
  end
  private_class_method :normalize
end
