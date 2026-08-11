require "test_helper"

class Resume::ImportTest < ActiveSupport::TestCase
  test "persists a Resume with ordered experiences and educations, parsing varied date formats" do
    resume = Resume::Import.call(file: fixture_path(valid_json), strategy: "regex", user: users(:jordan))

    assert_equal "json_mapper", resume.source
    assert_equal "Jane Doe", resume.name
    assert_equal "jane@example.com", resume.email
    assert_equal "555-123-4567", resume.phone
    assert_equal "Product-minded engineer.", resume.summary
    assert_equal [ "Go", "Kubernetes" ], resume.skills

    assert_equal [ "Initech", "Old Co" ], resume.experiences.map(&:company)
    assert_equal Date.new(2021, 3, 1), resume.experiences.first.starts_on
    assert_nil resume.experiences.first.ends_on
    assert_equal Date.new(2018, 1, 1), resume.experiences.second.starts_on
    assert_equal Date.new(2020, 1, 1), resume.experiences.second.ends_on

    assert_equal Date.new(2012, 1, 1), resume.educations.first.starts_on

    assert_equal [], resume.pending_items
    assert_equal [], resume.experiences.first.pending_items
    assert_equal [], resume.educations.first.pending_items
  end

  test "parses a starts_on that Date.parse can't handle as nil instead of raising" do
    json = {
      name: "Jane Doe",
      experiences: [
        { company: "Acme Corp", title: "Engineer", starts_on: "Summer 2020", ends_on: nil }
      ],
      educations: []
    }.to_json

    resume = Resume::Import.call(file: fixture_path(json), strategy: "regex", user: users(:jordan))

    assert_equal "Acme Corp", resume.experiences.first.company
    assert_nil resume.experiences.first.starts_on

    pending = resume.experiences.first.pending_items.find { |item| item["field"] == "starts_on" }
    assert_equal "unparsed_date", pending["kind"]
    assert_equal "Summer 2020", pending["raw_value"]
  end

  test "truncates experiences beyond MAX_EXPERIENCES and records a pending item" do
    json = {
      name: "Jane Doe",
      experiences: (1..Resume::Import::MAX_EXPERIENCES + 5).map do |n|
        { company: "Company #{n}", title: "Engineer" }
      end,
      educations: []
    }.to_json

    resume = Resume::Import.call(file: fixture_path(json), strategy: "regex", user: users(:jordan))

    assert_equal Resume::Import::MAX_EXPERIENCES, resume.experiences.count
    assert_equal "Company 1", resume.experiences.first.company
    assert_equal "Company #{Resume::Import::MAX_EXPERIENCES}", resume.experiences.last.company

    pending = resume.pending_items.find { |item| item["kind"] == "truncated_experiences" }
    assert_equal "experiences", pending["field"]
    assert_includes pending["reason"], "kept the first #{Resume::Import::MAX_EXPERIENCES} of #{Resume::Import::MAX_EXPERIENCES + 5}"
  end

  test "does not record a truncated_experiences pending item when under MAX_EXPERIENCES" do
    resume = Resume::Import.call(file: fixture_path(valid_json), strategy: "regex", user: users(:jordan))

    assert_nil resume.pending_items.find { |item| item["kind"] == "truncated_experiences" }
  end

  test "truncates bullets beyond MAX_BULLETS_PER_EXPERIENCE and records a pending item" do
    json = {
      name: "Jane Doe",
      experiences: [
        {
          company: "Acme Corp", title: "Engineer",
          bullets: (1..Resume::Import::MAX_BULLETS_PER_EXPERIENCE + 3).map { |n| "Did thing #{n}" }
        }
      ],
      educations: []
    }.to_json

    resume = Resume::Import.call(file: fixture_path(json), strategy: "regex", user: users(:jordan))

    experience = resume.experiences.first
    assert_equal Resume::Import::MAX_BULLETS_PER_EXPERIENCE, experience.bullets.size
    assert_equal "Did thing 1", experience.bullets.first
    assert_equal "Did thing #{Resume::Import::MAX_BULLETS_PER_EXPERIENCE}", experience.bullets.last

    pending = experience.pending_items.find { |item| item["kind"] == "truncated_bullets" }
    assert_equal "bullets", pending["field"]
    assert_includes pending["reason"],
      "kept the first #{Resume::Import::MAX_BULLETS_PER_EXPERIENCE} of #{Resume::Import::MAX_BULLETS_PER_EXPERIENCE + 3}"
  end

  test "does not record a truncated_bullets pending item when under MAX_BULLETS_PER_EXPERIENCE" do
    resume = Resume::Import.call(file: fixture_path(valid_json), strategy: "regex", user: users(:jordan))

    assert_nil resume.experiences.first.pending_items.find { |item| item["kind"] == "truncated_bullets" }
  end

  test "raises for an unknown strategy" do
    assert_raises(Resume::Import::UnsupportedFormatError) do
      Resume::Import.call(file: fixture_path(valid_json), strategy: "nope", user: users(:jordan))
    end
  end

  test "raises for an unsupported file format" do
    path = Rails.root.join("tmp/import_test_unsupported.txt").to_s
    File.write(path, "hello")

    assert_raises(Resume::Import::UnsupportedFormatError) do
      Resume::Import.call(file: path, strategy: "regex", user: users(:jordan))
    end
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "rolls back the whole import if an experience fails validation" do
    invalid_json = { experiences: [ { title: "Engineer" } ] }.to_json

    assert_no_difference [ "Resume.count", "Experience.count" ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        Resume::Import.call(file: fixture_path(invalid_json), strategy: "regex", user: users(:jordan))
      end
    end
  end

  test "drops a blank-company experience instead of rolling back the whole import" do
    # The second experience's title ("Store Manager") is deliberately genuine
    # (present in source_text) so it passes its own verification - isolating
    # the blank company field as the only reason that entry should be
    # dropped, rather than accidentally passing because of an unrelated
    # "title not found" mismatch.
    source_text = "Jane Doe. Experience: Senior Engineer at Acme Corp, 2020-01 to present. Also worked as Store Manager."
    fake_chat = FakeChat.new({
      "name" => "Jane Doe", "email" => nil, "phone" => nil, "summary" => nil,
      "skills" => [],
      "experiences" => [
        { "company" => "Acme Corp", "title" => "Senior Engineer", "location" => nil, "starts_on" => "2020-01", "ends_on" => nil, "bullets" => [] },
        { "company" => "", "title" => "Store Manager", "location" => nil, "starts_on" => nil, "ends_on" => nil, "bullets" => [] }
      ],
      "educations" => []
    })

    resume = assert_difference "Resume.count", 1 do
      Resume::Import.call(file: fixture_path(source_text), strategy: "llm", user: users(:jordan), chat: fake_chat)
    end

    assert_equal [ "Acme Corp" ], resume.experiences.map(&:company)
  end

  test "forwards a custom chat: to the Llm extractor when strategy is llm" do
    fake_chat = FakeChat.new({
      "name" => "Jane Doe", "email" => nil, "phone" => nil, "summary" => nil,
      "skills" => [], "experiences" => [], "educations" => []
    })

    resume = Resume::Import.call(file: fixture_path(valid_json), strategy: "llm", user: users(:jordan), chat: fake_chat)

    assert_equal "llm", resume.source
    assert_equal "Jane Doe", resume.name
  end

  test "does not forward chat: to extractors that don't accept it" do
    resume = Resume::Import.call(file: fixture_path(valid_json), strategy: "regex", user: users(:jordan), chat: FakeChat.new({}))

    assert_equal "json_mapper", resume.source
  end

  private

  FakeChat = Struct.new(:content_to_return) do
    def with_schema(_schema)
      self
    end

    def ask(_prompt, with: nil)
      Struct.new(:content).new(content_to_return)
    end
  end

  def valid_json
    {
      name: "Jane Doe",
      email: "jane@example.com",
      phone: "555-123-4567",
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
