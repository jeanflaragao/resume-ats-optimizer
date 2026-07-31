require "test_helper"

class BulletRewriterTest < ActiveSupport::TestCase
  FakeChat = Struct.new(:content_to_return) do
    attr_reader :schema, :prompt

    def with_schema(schema)
      @schema = schema
      self
    end

    def ask(prompt)
      @prompt = prompt
      Struct.new(:content).new(content_to_return)
    end
  end

  test "sends the bullets and job description to RubyLLM and returns the rewritten bullets" do
    fake_chat = FakeChat.new({ "bullets" => [ "Shipped a Ruby on Rails platform rewrite" ] })

    result = BulletRewriter.call(
      bullets: [ "Shipped a platform rewrite" ],
      job_description_text: "Looking for a Ruby on Rails engineer.",
      chat: fake_chat
    )

    assert_equal [ "Shipped a Ruby on Rails platform rewrite" ], result
    assert_equal BulletRewriter::Schema, fake_chat.schema
    assert_includes fake_chat.prompt, "Shipped a platform rewrite"
    assert_includes fake_chat.prompt, "Looking for a Ruby on Rails engineer."
  end

  test "returns an empty array without calling the LLM when there are no bullets" do
    fake_chat = FakeChat.new({ "bullets" => [ "should never be reached" ] })

    result = BulletRewriter.call(bullets: [], job_description_text: "Anything.", chat: fake_chat)

    assert_equal [], result
    assert_nil fake_chat.schema
  end

  test "raises if the LLM returns a different number of bullets than it was given" do
    fake_chat = FakeChat.new({ "bullets" => [ "Only one bullet back" ] })

    assert_raises(BulletRewriter::MismatchedBulletCountError) do
      BulletRewriter.call(
        bullets: [ "First bullet", "Second bullet" ],
        job_description_text: "Anything.",
        chat: fake_chat
      )
    end
  end
end
