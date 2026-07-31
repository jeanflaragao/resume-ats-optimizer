class Resume::ExtractionSchema < RubyLLM::Schema
  string :summary, required: false,
    description: "The candidate's professional summary/about section, verbatim or lightly condensed. Omit if none is present."

  array :skills, of: :string,
    description: "Skills explicitly listed in the document. Do not infer skills from job titles or bullets."

  array :experiences do
    object do
      string :company
      string :title
      string :location, required: false
      string :starts_on, required: false,
        description: "Start date as YYYY-MM-DD or YYYY-MM, using the most precision the document gives."
      string :ends_on, required: false,
        description: "End date as YYYY-MM-DD or YYYY-MM. Omit entirely if this is a current position."
      array :bullets, of: :string,
        description: "Bullet points/achievements for this role, verbatim from the document."
    end
  end

  array :educations do
    object do
      string :school
      string :degree, required: false
      string :field_of_study, required: false
      string :starts_on, required: false, description: "Start date as YYYY-MM-DD or YYYY-MM."
      string :ends_on, required: false, description: "End date as YYYY-MM-DD or YYYY-MM."
    end
  end
end
