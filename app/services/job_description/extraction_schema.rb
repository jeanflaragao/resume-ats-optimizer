class JobDescription::ExtractionSchema < RubyLLM::Schema
  string :title, required: false,
    description: "The job title being advertised, if stated."

  array :required_skills, of: :string,
    description: "Skills, technologies, or qualifications explicitly described as required, must-have, or essential."

  array :preferred_skills, of: :string,
    description: "Skills, technologies, or qualifications described as preferred, a plus, or nice-to-have."

  array :keywords, of: :string,
    description: "Other ATS-relevant keywords/phrases from the posting (tools, certifications, methodologies, domain terms) not already captured as a required or preferred skill."

  string :seniority_level, required: false,
    description: "The seniority the posting advertises, in its own words (e.g. Junior, Mid-level, Senior, Staff, Principal), if stated. Do not infer one from the responsibilities."

  # Optional rather than nullable-by-union: RubyLLM::Schema's `required: false`
  # already omits the key from the JSON Schema's `required` list, which is how
  # `title` above expresses the same thing.
  integer :years_experience_min, required: false, minimum: 0,
    description: "The minimum number of years of experience the posting explicitly requires. Omit unless the posting states a number."

  array :responsibilities, of: :string,
    description: "What the role is responsible for doing day to day, as described by the posting."

  array :education_requirements, of: :string,
    description: "Degrees, fields of study, or certifications the posting asks for, required or preferred."

  array :soft_skills, of: :string,
    description: "Non-technical attributes the posting asks for (communication, mentoring, collaboration, ownership)."
end
