class JobDescription::ExtractionSchema < RubyLLM::Schema
  string :title, required: false,
    description: "The job title being advertised, if stated."

  array :required_skills, of: :string,
    description: "Skills, technologies, or qualifications explicitly described as required, must-have, or essential."

  array :preferred_skills, of: :string,
    description: "Skills, technologies, or qualifications described as preferred, a plus, or nice-to-have."

  array :keywords, of: :string,
    description: "Other ATS-relevant keywords/phrases from the posting (tools, certifications, methodologies, domain terms) not already captured as a required or preferred skill."
end
