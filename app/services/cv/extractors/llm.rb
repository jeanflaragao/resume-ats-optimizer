class Cv::Extractors::Llm
  PROMPT = <<~PROMPT.freeze
    Extract the professional summary, skills, work experience, and education from
    the attached document into the given schema.

    Only include information that is explicitly present in the document. Do not
    invent, infer, or embellish company names, job titles, dates, schools, or
    bullet points that are not literally stated. If a section is absent, return
    an empty list (or omit the summary) rather than guessing.
  PROMPT

  def self.call(file_path:, chat: RubyLLM.chat)
    response = chat.with_schema(Cv::ExtractionSchema).ask(PROMPT, with: file_path)
    response.content
  end
end
