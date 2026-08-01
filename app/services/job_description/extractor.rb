class JobDescription::Extractor
  INSTRUCTIONS = <<~PROMPT.freeze
    Extract the key requirements and keywords an Applicant Tracking System would
    match against from the job description below, into the given schema.

    Only include requirements and keywords explicitly stated or clearly implied by
    the posting. Do not invent skills, qualifications, or responsibilities that
    aren't mentioned.
  PROMPT

  def self.call(text:, chat: LlmCallGuard.chat)
    response = chat.with_schema(JobDescription::ExtractionSchema).ask("#{INSTRUCTIONS}\nJob description:\n#{text}")
    response.content
  end
end
