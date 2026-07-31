# Deterministic (non-LLM) matching between a Resume's actual content and a
# job description's extracted requirements. Only ever sorts requirement terms
# into "matched"/"missing" buckets based on whether they literally appear in
# the resume's skills, summary, or experience bullets — never infers or adds
# anything not already present in the resume.
class Comparison
  Result = Data.define(
    :matched_required_skills, :missing_required_skills,
    :matched_preferred_skills, :missing_preferred_skills,
    :matched_keywords, :missing_keywords
  )

  def self.call(resume:, requirements:)
    new(resume: resume, requirements: requirements).call
  end

  def initialize(resume:, requirements:)
    @resume = resume
    @requirements = requirements
  end

  def call
    matched_required, missing_required = partition(required_skills)
    matched_preferred, missing_preferred = partition(preferred_skills)
    matched_keywords, missing_keywords = partition(keywords)

    Result.new(
      matched_required_skills: matched_required,
      missing_required_skills: missing_required,
      matched_preferred_skills: matched_preferred,
      missing_preferred_skills: missing_preferred,
      matched_keywords: matched_keywords,
      missing_keywords: missing_keywords
    )
  end

  private

  attr_reader :resume, :requirements

  def required_skills
    Array(requirements["required_skills"]).reject(&:blank?)
  end

  def preferred_skills
    Array(requirements["preferred_skills"]).reject(&:blank?)
  end

  def keywords
    Array(requirements["keywords"]).reject(&:blank?)
  end

  def partition(terms)
    terms.partition { |term| present_in_resume?(term) }
  end

  # Word-boundary match rather than plain substring, so a short term like "Go"
  # doesn't false-positive against "Google" or "Django".
  def present_in_resume?(term)
    pattern = /(?<![[:alnum:]])#{Regexp.escape(term.downcase)}(?![[:alnum:]])/
    resume_text.match?(pattern)
  end

  def resume_text
    @resume_text ||= (
      Array(resume.skills) +
      [ resume.summary ] +
      resume.experiences.flat_map { |experience| Array(experience.bullets) }
    ).compact.join("\n").downcase
  end
end
