require "test_helper"

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

  test "sends the file and schema to RubyLLM and returns the parsed content" do
    expected_data = { "summary" => "A summary", "skills" => [ "Ruby" ], "experiences" => [], "educations" => [] }
    fake_chat = FakeChat.new(expected_data)

    result = Resume::Extractors::Llm.call(file_path: "resume.pdf", chat: fake_chat)

    assert_equal expected_data, result
    assert_equal Resume::ExtractionSchema, fake_chat.schema
    assert_equal "resume.pdf", fake_chat.attached_file
    assert_includes fake_chat.prompt, "Extract"
  end
end
