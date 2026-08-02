# Shared seam for counting real provider requests in a test. Replaces
# RubyLLM.chat -- the seam LlmCallGuard::MeteredChat itself uses
# (llm_call_guard.rb:252) -- so ENABLE_REAL_LLM_CALLS can be true without any
# connection being built. Extracted from LlmCallGuardTest, where it started as
# a private helper, once a second test file needed to count the same thing.
module RecordingLlm
  # Mimics RubyLLM::Chat's message accumulation so a shared chat is *visible*
  # rather than having to be inferred: #ask appends the user message
  # (ruby_llm/chat.rb:40 -> :167) and the assistant reply is appended too
  # (:229), and every ask re-sends the whole array. Recording messages.size at
  # each ask is therefore exactly the payload-growth signal ADR-0019 guards.
  class RecordingChat
    attr_reader :messages

    def initialize(sizes_log, prompts_log = [], vary: false)
      @sizes_log = sizes_log
      @prompts_log = prompts_log
      @vary = vary
      @messages = []
    end

    def with_schema(schema)
      @schema = schema
      self
    end

    def ask(prompt = nil, **)
      @messages << { role: :user, content: prompt }
      @sizes_log << @messages.size
      @prompts_log << prompt
      reply = { "bullets" => rewrite(bullets_in(prompt)) }
      @messages << { role: :assistant, content: reply }
      Struct.new(:content).new(reply)
    end

    private

    def bullets_in(prompt)
      prompt.to_s.scan(/^\d+\.\s+(.+)$/).flatten
    end

    # Default: echo each bullet back unchanged, which is what the cap and
    # payload tests want. With vary: true, rotate each bullet's own words by
    # the number of requests seen so far, so no two runs of the same pipeline
    # produce the same rewrite. That is what makes "the download delivered what
    # the preview showed" a real assertion instead of a tautology -- a
    # deterministic stub would satisfy it with no cache at all.
    #
    # Rotation is used rather than any added marker because BulletRewriter
    # checks every rewrite against its own original with FidelityCheck: a new
    # token or digit fails, the original is substituted back, and the runs
    # become identical again -- re-tautologising the test from the other side.
    # Reordering a bullet's own words introduces neither.
    def rewrite(bullets)
      return bullets unless @vary

      bullets.map { |bullet| bullet.split.rotate(@sizes_log.size).join(" ") }
    end
  end

  # Yields the log of messages-array sizes seen at each ask, one entry per
  # provider request. prompts_log, when passed, collects the prompt text of
  # each request in the same order.
  def with_recording_chat(prompts_log = [], vary: false)
    log = []
    original = RubyLLM.method(:chat)
    RubyLLM.define_singleton_method(:chat) { |*, **| RecordingChat.new(log, prompts_log, vary: vary) }
    yield log
  ensure
    RubyLLM.define_singleton_method(:chat, original)
  end
end
