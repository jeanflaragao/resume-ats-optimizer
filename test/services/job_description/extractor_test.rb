require "test_helper"

class JobDescription::ExtractorTest < ActiveSupport::TestCase
  FakeChat = Struct.new(:content_to_return) do
    attr_reader :schema, :prompt

    def with_schema(schema)
      @schema = schema
      self
    end

    def ask(prompt, with: nil)
      @prompt = prompt
      Struct.new(:content).new(content_to_return)
    end
  end

  test "sends the job description text and schema to RubyLLM and returns the parsed content" do
    expected_data = {
      "title" => "Senior Ruby Engineer",
      "required_skills" => [ "Ruby", "Rails" ],
      "preferred_skills" => [ "Postgres" ],
      "keywords" => [ "AWS" ]
    }
    fake_chat = FakeChat.new(expected_data)

    result = JobDescription::Extractor.call(text: "We need a Senior Ruby Engineer...", chat: fake_chat)

    assert_equal expected_data, result
    assert_equal JobDescription::ExtractionSchema, fake_chat.schema
    assert_includes fake_chat.prompt, "Extract"
    assert_includes fake_chat.prompt, "We need a Senior Ruby Engineer..."
  end
end
