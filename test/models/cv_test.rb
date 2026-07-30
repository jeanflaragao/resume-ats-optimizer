require "test_helper"

class CvTest < ActiveSupport::TestCase
  test "skills defaults to an empty array" do
    assert_equal [], Cv.new.skills
  end

  test "skills round-trips as an array" do
    cv = cvs(:one)
    assert_equal [ "Ruby", "Rails", "PostgreSQL" ], cv.skills
  end

  test "experiences are ordered by position" do
    assert_equal [ "Acme Corp", "Globex" ], cvs(:one).experiences.map(&:company)
  end

  test "destroying a cv destroys its experiences and educations" do
    cv = cvs(:one)

    assert_difference "Experience.count", -cv.experiences.count do
      assert_difference "Education.count", -cv.educations.count do
        cv.destroy
      end
    end
  end
end
