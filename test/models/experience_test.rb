require "test_helper"

class ExperienceTest < ActiveSupport::TestCase
  test "requires company and title" do
    experience = Experience.new(cv: cvs(:one))

    assert_not experience.valid?
    assert_includes experience.errors.attribute_names, :company
    assert_includes experience.errors.attribute_names, :title
  end

  test "bullets defaults to an empty array" do
    assert_equal [], Experience.new.bullets
  end

  test "bullets round-trips as an array" do
    assert_equal(
      [ "Led migration to microservices", "Mentored three junior engineers" ],
      experiences(:most_recent).bullets
    )
  end
end
