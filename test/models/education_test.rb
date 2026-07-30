require "test_helper"

class EducationTest < ActiveSupport::TestCase
  test "requires school" do
    education = Education.new(cv: cvs(:one))

    assert_not education.valid?
    assert_includes education.errors.attribute_names, :school
  end

  test "belongs to a cv" do
    assert_equal cvs(:one), educations(:one).cv
  end
end
