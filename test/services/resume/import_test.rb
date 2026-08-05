require "test_helper"

class Resume::ImportTest < ActiveSupport::TestCase
  test "persists a Resume with ordered experiences and educations, parsing varied date formats" do
    resume = Resume::Import.call(file: fixture_path(valid_json), strategy: "regex")

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
  end

  test "parses a starts_on that Date.parse can't handle as nil instead of raising" do
    json = {
      name: "Jane Doe",
      experiences: [
        { company: "Acme Corp", title: "Engineer", starts_on: "Summer 2020", ends_on: nil }
      ],
      educations: []
    }.to_json

    resume = Resume::Import.call(file: fixture_path(json), strategy: "regex")

    assert_equal "Acme Corp", resume.experiences.first.company
    assert_nil resume.experiences.first.starts_on
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
      Resume::Import.call(file: fixture_path(source_text), strategy: "llm", chat: fake_chat)
    end

    assert_equal [ "Acme Corp" ], resume.experiences.map(&:company)
  end

  test "forwards a custom chat: to the Llm extractor when strategy is llm" do
    fake_chat = FakeChat.new({
      "name" => "Jane Doe", "email" => nil, "phone" => nil, "summary" => nil,
      "skills" => [], "experiences" => [], "educations" => []
    })

    resume = Resume::Import.call(file: fixture_path(valid_json), strategy: "llm", chat: fake_chat)

    assert_equal "llm", resume.source
    assert_equal "Jane Doe", resume.name
  end

  test "does not forward chat: to extractors that don't accept it" do
    resume = Resume::Import.call(file: fixture_path(valid_json), strategy: "regex", chat: FakeChat.new({}))

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
