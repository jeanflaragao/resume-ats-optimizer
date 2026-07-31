require "test_helper"

class EducationTest < ActiveSupport::TestCase
  test "requires school" do
    education = Education.new(resume: resumes(:one))

    assert_not education.valid?
    assert_includes education.errors.attribute_names, :school
  end

  test "belongs to a resume" do
    assert_equal resumes(:one), educations(:one).resume
  end
end
