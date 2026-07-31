require "test_helper"
require "prawn"

class Resume::Extractors::LlmTest < ActiveSupport::TestCase
  FakeChat = Struct.new(:content_to_return) do
    attr_reader :schema, :prompt, :attached_file

    def with_schema(schema)
      @schema = schema
      self
    end

    def ask(prompt, with:)
      @prompt = prompt
      @attached_file = with
      Struct.new(:content).new(content_to_return)
    end
  end

  test "keeps every field when it's genuinely present in the source PDF" do
    extracted = {
      "summary" => "Product-minded engineer with experience building scalable systems.",
      "skills" => [ "Ruby", "Rails", "PostgreSQL" ],
      "experiences" => [
        {
          "company" => "Acme Corp", "title" => "Senior Engineer", "location" => nil,
          "starts_on" => "2020-01", "ends_on" => nil,
          "bullets" => [ "Led migration to microservices", "Mentored three junior engineers" ]
        }
      ],
      "educations" => [
        { "school" => "State University", "degree" => "B.S. Computer Science", "field_of_study" => nil, "starts_on" => nil, "ends_on" => nil }
      ]
    }
    fake_chat = FakeChat.new(extracted)

    result = Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat)

    assert_equal extracted, result
    assert_equal Resume::ExtractionSchema, fake_chat.schema
    assert_equal sample_pdf_path, fake_chat.attached_file
    assert_includes fake_chat.prompt, "Extract"
  end

  test "drops a whole experience entry when its company isn't in the source" do
    fake_chat = FakeChat.new(base_extraction.deep_merge(
      "experiences" => [ base_experience.merge("company" => "Wonka Industries") ]
    ))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_equal [], result["experiences"]
    assert_includes log_output, "Wonka Industries"
  end

  test "drops only a fabricated bullet, keeping real ones from the same experience" do
    fake_chat = FakeChat.new(base_extraction.deep_merge(
      "experiences" => [ base_experience.merge("bullets" => [ "Led migration to microservices", "Increased revenue by 200%" ]) ]
    ))

    result = Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat)

    assert_equal [ "Led migration to microservices" ], result["experiences"].first["bullets"]
  end

  test "drops only a hallucinated skill, keeping real ones" do
    fake_chat = FakeChat.new(base_extraction.deep_merge("skills" => [ "Ruby", "Kubernetes" ]))

    result = Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat)

    assert_equal [ "Ruby" ], result["skills"]
  end

  test "keeps a legitimately condensed summary" do
    fake_chat = FakeChat.new(base_extraction.deep_merge(
      "summary" => "Product-minded engineer building scalable systems."
    ))

    result = Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat)

    assert_equal "Product-minded engineer building scalable systems.", result["summary"]
  end

  test "nulls a fabricated start date whose year isn't in the source" do
    fake_chat = FakeChat.new(base_extraction.deep_merge(
      "experiences" => [ base_experience.merge("starts_on" => "1999-05") ]
    ))

    result = Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat)

    assert_nil result["experiences"].first["starts_on"]
    assert_equal "Acme Corp", result["experiences"].first["company"]
  end

  test "keeps a fully faithful extraction from a JSON source unchanged" do
    extracted = {
      "summary" => "Just a summary.",
      "skills" => [ "Go" ],
      "experiences" => [],
      "educations" => []
    }
    fake_chat = FakeChat.new(extracted)

    result = Resume::Extractors::Llm.call(file_path: json_fixture_path(extracted), chat: fake_chat)

    assert_equal extracted, result
  end

  test "raises a clear error when the file doesn't exist" do
    fake_chat = FakeChat.new(base_extraction)

    assert_raises(ArgumentError) do
      Resume::Extractors::Llm.call(file_path: "tmp/does_not_exist.pdf", chat: fake_chat)
    end
  end

  private

  def base_experience
    {
      "company" => "Acme Corp", "title" => "Senior Engineer", "location" => nil,
      "starts_on" => "2020-01", "ends_on" => nil,
      "bullets" => [ "Led migration to microservices" ]
    }
  end

  def base_extraction
    {
      "summary" => "Product-minded engineer with experience building scalable systems.",
      "skills" => [ "Ruby" ],
      "experiences" => [ base_experience ],
      "educations" => []
    }
  end

  def sample_pdf_path
    @sample_pdf_path ||= begin
      path = Rails.root.join("tmp/llm_extractor_test_sample.pdf").to_s
      Prawn::Document.generate(path) do
        text "Jane Doe", size: 20
        text "Summary"
        text "Product-minded engineer with experience building scalable systems."
        text "Experience"
        text "Senior Engineer"
        text "Acme Corp"
        text "Jan 2020 - Present"
        text "• Led migration to microservices"
        text "• Mentored three junior engineers"
        text "Education"
        text "State University"
        text "B.S. Computer Science"
        text "Skills"
        text "Ruby, Rails, PostgreSQL"
      end
      path
    end
  end

  def json_fixture_path(data)
    path = Rails.root.join("tmp/llm_extractor_test_#{object_id}_#{rand(10_000)}.json").to_s
    File.write(path, data.to_json)
    path
  end

  def with_captured_log
    original_logger = Rails.logger
    io = StringIO.new
    Rails.logger = Logger.new(io)
    result = yield
    [ result, io.string ]
  ensure
    Rails.logger = original_logger
  end
end
