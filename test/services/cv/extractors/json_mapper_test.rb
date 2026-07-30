require "test_helper"

class Cv::Extractors::JsonMapperTest < ActiveSupport::TestCase
  test "maps a well-formed JSON export into the normalized hash shape" do
    result = Cv::Extractors::JsonMapper.call(file_path: fixture_path(<<~JSON))
      {
        "summary": "Product-minded engineer.",
        "skills": ["Go", "Kubernetes"],
        "experiences": [
          { "company": "Initech", "title": "Staff Engineer", "starts_on": "2021-03", "bullets": ["Shipped the platform rewrite"] }
        ],
        "educations": [
          { "school": "Tech Institute", "degree": "M.S.", "starts_on": "2010", "ends_on": "2012" }
        ]
      }
    JSON

    assert_equal "Product-minded engineer.", result["summary"]
    assert_equal [ "Go", "Kubernetes" ], result["skills"]
    assert_equal "Initech", result["experiences"].first["company"]
    assert_equal [ "Shipped the platform rewrite" ], result["experiences"].first["bullets"]
    assert_equal "Tech Institute", result["educations"].first["school"]
  end

  test "defaults missing collections to empty arrays" do
    result = Cv::Extractors::JsonMapper.call(file_path: fixture_path('{"summary": "Just a summary."}'))

    assert_equal [], result["skills"]
    assert_equal [], result["experiences"]
    assert_equal [], result["educations"]
  end

  test "raises InvalidJsonError for malformed JSON" do
    assert_raises(Cv::Extractors::JsonMapper::InvalidJsonError) do
      Cv::Extractors::JsonMapper.call(file_path: fixture_path("not json"))
    end
  end

  private

  def fixture_path(content)
    path = Rails.root.join("tmp/json_mapper_test_#{object_id}.json").to_s
    File.write(path, content)
    path
  end
end
