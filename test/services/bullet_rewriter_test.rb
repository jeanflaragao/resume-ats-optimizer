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
    fake_chat = FakeChat.new({ "bullets" => [ "Delivered a platform rewrite for backend services" ] })

    result = BulletRewriter.call(
      bullets: [ "Shipped a platform rewrite for backend services" ],
      job_description_text: "Looking for a backend engineer with platform rewrite experience.",
      chat: fake_chat
    )

    assert_equal [ "Delivered a platform rewrite for backend services" ], result
    assert_equal BulletRewriter::Schema, fake_chat.schema
    assert_includes fake_chat.prompt, "Shipped a platform rewrite for backend services"
    assert_includes fake_chat.prompt, "Looking for a backend engineer with platform rewrite experience."
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

  test "falls back to the original bullet and logs a warning when a rewrite fails its fidelity check" do
    fake_chat = FakeChat.new({ "bullets" => [ "Built REST APIs using Kubernetes and reduced latency by 40%" ] })

    result, log_output = with_captured_log do
      BulletRewriter.call(bullets: [ "Built REST APIs" ], job_description_text: "Anything.", chat: fake_chat)
    end

    assert_equal [ "Built REST APIs" ], result
    assert_includes log_output, "bullet 1"
    assert_includes log_output, "kubernetes"
  end

  test "fidelity-check fallback log does not contain the original bullet text" do
    original = "Built REST APIs using Kubernetes and reduced latency by 40%"
    # Large case: 8 significant tokens not in the source — forces the cap to engage (>5).
    fabricated = "Pioneered quantum blockchain synergies across worldwide enterprise platforms"
    fake_chat = FakeChat.new({ "bullets" => [ fabricated ] })

    _, log_output = with_captured_log do
      BulletRewriter.call(bullets: [ original ], job_description_text: "Anything.", chat: fake_chat)
    end

    assert_includes log_output, "unverifiable"
    assert_includes log_output, "(+", "expected capped token list with overflow marker"
    assert_not_includes log_output, original
    assert_not_includes log_output, fabricated
    fabricated.split.each_cons(4) do |run|
      assert_not_includes log_output, run.join(" "), "log must not contain 4-word run: #{run.join(' ')}"
    end

    # Small case: all tokens fit within the cap — no overflow marker, consecutive-word check is the only guard.
    small_fabricated = "Pioneered quantum blockchain synergies platforms"
    fake_chat2 = FakeChat.new({ "bullets" => [ small_fabricated ] })

    _, log2 = with_captured_log do
      BulletRewriter.call(bullets: [ original ], job_description_text: "Anything.", chat: fake_chat2)
    end

    assert_not_includes log2, original
    assert_not_includes log2, small_fabricated
    small_fabricated.split.each_cons(4) do |run|
      assert_not_includes log2, run.join(" "), "log must not contain 4-word run: #{run.join(' ')}"
    end
  end

  test "only falls back the bullet that fails fidelity, keeping the one that passes, in a mixed batch" do
    fake_chat = FakeChat.new({
      "bullets" => [
        "Delivered a platform rewrite for backend services",
        "Built REST APIs using Kubernetes and reduced latency by 40%"
      ]
    })

    result = BulletRewriter.call(
      bullets: [ "Shipped a platform rewrite for backend services", "Built REST APIs" ],
      job_description_text: "Anything.",
      chat: fake_chat
    )

    assert_equal [ "Delivered a platform rewrite for backend services", "Built REST APIs" ], result
  end

  private

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
