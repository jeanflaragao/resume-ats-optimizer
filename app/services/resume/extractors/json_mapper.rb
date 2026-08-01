class Resume::Extractors::JsonMapper
  class InvalidJsonError < StandardError; end

  def self.call(file_path:)
    data = JSON.parse(File.read(file_path))
  rescue JSON::ParserError => e
    raise InvalidJsonError, "Could not parse #{file_path} as JSON: #{e.message}"
  else
    {
      "name" => data["name"],
      "email" => data["email"],
      "phone" => data["phone"],
      "summary" => data["summary"],
      "skills" => Array(data["skills"]),
      "experiences" => Array(data["experiences"]).map { |experience| map_experience(experience) },
      "educations" => Array(data["educations"]).map { |education| map_education(education) }
    }
  end

  def self.map_experience(experience)
    {
      "company" => experience["company"],
      "title" => experience["title"],
      "location" => experience["location"],
      "starts_on" => experience["starts_on"],
      "ends_on" => experience["ends_on"],
      "bullets" => Array(experience["bullets"])
    }
  end
  private_class_method :map_experience

  def self.map_education(education)
    {
      "school" => education["school"],
      "degree" => education["degree"],
      "field_of_study" => education["field_of_study"],
      "starts_on" => education["starts_on"],
      "ends_on" => education["ends_on"]
    }
  end
  private_class_method :map_education
end
