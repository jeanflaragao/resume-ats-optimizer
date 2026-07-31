require "test_helper"

class Resume::ImportTest < ActiveSupport::TestCase
  test "persists a Resume with ordered experiences and educations, parsing varied date formats" do
    resume = Resume::Import.call(file: fixture_path(valid_json), strategy: "regex")

    assert_equal "json_mapper", resume.source
    assert_equal "Product-minded engineer.", resume.summary
    assert_equal [ "Go", "Kubernetes" ], resume.skills

    assert_equal [ "Initech", "Old Co" ], resume.experiences.map(&:company)
    assert_equal Date.new(2021, 3, 1), resume.experiences.first.starts_on
    assert_nil resume.experiences.first.ends_on
    assert_equal Date.new(2018, 1, 1), resume.experiences.second.starts_on
    assert_equal Date.new(2020, 1, 1), resume.experiences.second.ends_on

    assert_equal Date.new(2012, 1, 1), resume.educations.first.starts_on
  end

  test "raises for an unknown strategy" do
    assert_raises(Resume::Import::UnsupportedFormatError) do
      Resume::Import.call(file: fixture_path(valid_json), strategy: "nope")
    end
  end

  test "raises for an unsupported file format" do
    path = Rails.root.join("tmp/import_test_unsupported.txt").to_s
    File.write(path, "hello")

    assert_raises(Resume::Import::UnsupportedFormatError) do
      Resume::Import.call(file: path, strategy: "regex")
    end
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "rolls back the whole import if an experience fails validation" do
    invalid_json = { experiences: [ { title: "Engineer" } ] }.to_json

    assert_no_difference [ "Resume.count", "Experience.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        Resume::Import.call(file: fixture_path(invalid_json), strategy: "regex")
      end
    end
  end

  private

  def valid_json
    {
      summary: "Product-minded engineer.",
      skills: [ "Go", "Kubernetes" ],
      experiences: [
        { company: "Initech", title: "Staff Engineer", starts_on: "2021-03", ends_on: nil, bullets: [ "Shipped the platform rewrite" ] },
        { company: "Old Co", title: "Engineer", starts_on: "2018", ends_on: "2020" }
      ],
      educations: [
        { school: "Tech Institute", starts_on: "2012" }
      ]
    }.to_json
  end

  def fixture_path(content)
    path = Rails.root.join("tmp/import_test_#{object_id}_#{rand(10_000)}.json").to_s
    File.write(path, content)
    path
  end
end
