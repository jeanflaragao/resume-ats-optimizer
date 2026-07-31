require "test_helper"

class ResumeTest < ActiveSupport::TestCase
  test "skills defaults to an empty array" do
    assert_equal [], Resume.new.skills
  end

  test "skills round-trips as an array" do
    resume = resumes(:one)
    assert_equal [ "Ruby", "Rails", "PostgreSQL" ], resume.skills
  end

  test "experiences are ordered by position" do
    assert_equal [ "Acme Corp", "Globex" ], resumes(:one).experiences.map(&:company)
  end

  test "destroying a resume destroys its experiences and educations" do
    resume = resumes(:one)

    assert_difference "Experience.count", -resume.experiences.count do
      assert_difference "Education.count", -resume.educations.count do
        resume.destroy
      end
    end
  end
end
