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
      "name" => "Jane Doe",
      "email" => "jane@example.com",
      "phone" => "555-123-4567",
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
    assert_includes log_output, "experience entry"
    assert_not_includes log_output, "Wonka Industries"
  end

  test "drops a whole experience entry when its company is blank" do
    fake_chat = FakeChat.new(base_extraction.deep_merge(
      "experiences" => [ base_experience.merge("company" => "") ]
    ))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_equal [], result["experiences"]
    assert_includes log_output, "required field blank"
  end

  test "drops a whole experience entry when its title is nil" do
    fake_chat = FakeChat.new(base_extraction.deep_merge(
      "experiences" => [ base_experience.merge("title" => nil) ]
    ))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_equal [], result["experiences"]
    assert_includes log_output, "required field blank"
  end

  test "drops a whole education entry when its school is blank" do
    fake_chat = FakeChat.new(base_extraction.deep_merge(
      "educations" => [ { "school" => "", "degree" => "B.S. Computer Science", "field_of_study" => nil, "starts_on" => nil, "ends_on" => nil } ]
    ))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_equal [], result["educations"]
    assert_includes log_output, "required field blank"
  end

  test "drops a whole education entry when its school isn't in the source" do
    fake_chat = FakeChat.new(base_extraction.deep_merge(
      "educations" => [ { "school" => "Wonka University", "degree" => "B.S. Computer Science", "field_of_study" => nil, "starts_on" => nil, "ends_on" => nil } ]
    ))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_equal [], result["educations"]
    assert_includes log_output, "not found in source text"
    assert_not_includes log_output, "Wonka University"
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

  test "drops a fabricated name without logging the raw value" do
    fake_chat = FakeChat.new(base_extraction.deep_merge("name" => "John Smith"))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_nil result["name"]
    assert_includes log_output, "name"
    assert_not_includes log_output, "John Smith"
  end

  test "drops a fabricated email without logging the raw value" do
    fake_chat = FakeChat.new(base_extraction.deep_merge("email" => "someone-else@example.com"))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_nil result["email"]
    assert_includes log_output, "email"
    assert_not_includes log_output, "someone-else@example.com"
  end

  test "drops a fabricated phone without logging the raw value" do
    fake_chat = FakeChat.new(base_extraction.deep_merge("phone" => "999-999-9999"))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_nil result["phone"]
    assert_includes log_output, "phone"
    assert_not_includes log_output, "999-999-9999"
  end

  test "keeps a phone number that's only reformatted, not fabricated" do
    fake_chat = FakeChat.new(base_extraction.deep_merge("phone" => "(555) 123-4567"))

    result = Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat)

    assert_equal "(555) 123-4567", result["phone"]
  end

  test "keeps a fully faithful extraction from a JSON source unchanged" do
    extracted = {
      "name" => "Jane Doe",
      "email" => "jane@example.com",
      "phone" => "555-123-4567",
      "summary" => "Just a summary.",
      "skills" => [ "Go" ],
      "experiences" => [],
      "educations" => []
    }
    fake_chat = FakeChat.new(extracted)

    result = Resume::Extractors::Llm.call(file_path: json_fixture_path(extracted), chat: fake_chat)

    assert_equal extracted, result
  end

  test "drops a fabricated summary without logging the raw summary text" do
    # Large case: >5 unverifiable tokens — overflow marker proves the cap is applied.
    fabricated = "Pioneered groundbreaking quantum blockchain synergies worldwide"
    fake_chat = FakeChat.new(base_extraction.deep_merge("summary" => fabricated))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_nil result["summary"]
    assert_includes log_output, "summary"
    assert_includes log_output, "unverifiable tokens"
    assert_includes log_output, "(+", "expected capped token list with overflow marker"
    assert_not_includes log_output, fabricated
    fabricated.split.each_cons(4) do |run|
      assert_not_includes log_output, run.join(" "), "log must not contain 4-word run: #{run.join(' ')}"
    end

    # Small case: all tokens fit within the cap — no overflow marker, consecutive-word check is the only guard.
    small_fabricated = "Pioneered quantum blockchain synergies platforms"
    fake_chat2 = FakeChat.new(base_extraction.deep_merge("summary" => small_fabricated))

    _, log2 = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat2) }

    assert_not_includes log2, small_fabricated
    small_fabricated.split.each_cons(4) do |run|
      assert_not_includes log2, run.join(" "), "log must not contain 4-word run: #{run.join(' ')}"
    end
  end

  test "drops a fabricated bullet without logging the raw bullet text" do
    # Large case: >5 unverifiable tokens — overflow marker proves the cap is applied.
    fabricated = "Pioneered quantum blockchain synergies across worldwide enterprise platforms"
    fake_chat = FakeChat.new(base_extraction.deep_merge(
      "experiences" => [ base_experience.merge("bullets" => [ fabricated ]) ]
    ))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_equal [], result["experiences"].first["bullets"]
    assert_includes log_output, "bullet"
    assert_includes log_output, "unverifiable tokens"
    assert_includes log_output, "(+", "expected capped token list with overflow marker"
    assert_not_includes log_output, fabricated
    fabricated.split.each_cons(4) do |run|
      assert_not_includes log_output, run.join(" "), "log must not contain 4-word run: #{run.join(' ')}"
    end

    # Small case: all tokens fit within the cap — no overflow marker, consecutive-word check is the only guard.
    small_fabricated = "Pioneered quantum blockchain synergies platforms"
    fake_chat2 = FakeChat.new(base_extraction.deep_merge(
      "experiences" => [ base_experience.merge("bullets" => [ small_fabricated ]) ]
    ))

    _, log2 = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat2) }

    assert_not_includes log2, small_fabricated
    small_fabricated.split.each_cons(4) do |run|
      assert_not_includes log2, run.join(" "), "log must not contain 4-word run: #{run.join(' ')}"
    end
  end

  test "drops a fabricated skill without logging the raw skill value" do
    fake_chat = FakeChat.new(base_extraction.deep_merge("skills" => [ "Ruby", "QuantumFramework" ]))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_equal [ "Ruby" ], result["skills"]
    assert_includes log_output, "skill"
    assert_not_includes log_output, "QuantumFramework"
  end

  test "drops a fabricated location without logging the raw location value" do
    fake_chat = FakeChat.new(base_extraction.deep_merge(
      "experiences" => [ base_experience.merge("location" => "Mars Colony Seven") ]
    ))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_nil result["experiences"].first["location"]
    assert_includes log_output, "location"
    assert_not_includes log_output, "Mars Colony Seven"
  end

  test "drops a fabricated start date without logging the raw date string" do
    fake_chat = FakeChat.new(base_extraction.deep_merge(
      "experiences" => [ base_experience.merge("starts_on" => "1999-05") ]
    ))

    result, log_output = with_captured_log { Resume::Extractors::Llm.call(file_path: sample_pdf_path, chat: fake_chat) }

    assert_nil result["experiences"].first["starts_on"]
    assert_includes log_output, "starts_on"
    assert_not_includes log_output, "1999-05"
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
      "name" => "Jane Doe",
      "email" => "jane@example.com",
      "phone" => "555-123-4567",
      "summary" => "Product-minded engineer with experience building scalable systems.",
      "skills" => [ "Ruby" ],
      "experiences" => [ base_experience ],
      "educations" => []
    }
  end

  def sample_pdf_path
    @sample_pdf_path ||= begin
      path = Rails.root.join("tmp/llm_extractor_test_sample_#{object_id}_#{rand(10_000)}.pdf").to_s
      Prawn::Document.generate(path) do
        text "Jane Doe", size: 20
        text "jane@example.com"
        text "555-123-4567"
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
