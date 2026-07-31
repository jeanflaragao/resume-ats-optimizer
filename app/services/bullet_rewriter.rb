# LLM call that rephrases a resume's existing bullets to pick up a job
# posting's terminology/keywords, without adding anything not already true of
# the original bullet. Pairs with Comparison (deterministic) rather than
# replacing it — this only rewords, it never decides what's a match.
class BulletRewriter
  class MismatchedBulletCountError < StandardError; end

  class Schema < RubyLLM::Schema
    array :bullets, of: :string,
      description: "Rewritten bullets, exactly one per input bullet and in the same order."
  end

  INSTRUCTIONS = <<~PROMPT.freeze
    Rewrite the resume bullets below to align their language with the job
    description's terminology and keywords, without changing what actually
    happened.

    Rules:
    - Do not invent, add, or imply any skill, technology, achievement, metric,
      or responsibility that is not already stated in the original bullet.
    - You may rephrase wording and substitute a bullet's own terms for closer
      synonyms/keywords used in the job description, but the underlying facts
      and scope of each bullet must stay the same.
    - Return exactly one rewritten bullet per input bullet, in the same order.
  PROMPT

  def self.call(bullets:, job_description_text:, chat: RubyLLM.chat)
    new(bullets: bullets, job_description_text: job_description_text, chat: chat).call
  end

  def initialize(bullets:, job_description_text:, chat:)
    @bullets = bullets
    @job_description_text = job_description_text
    @chat = chat
  end

  def call
    return [] if bullets.empty?

    rewritten = chat.with_schema(Schema).ask(prompt).content["bullets"]

    if rewritten.size != bullets.size
      raise MismatchedBulletCountError, "Expected #{bullets.size} rewritten bullets, got #{rewritten.size}"
    end

    rewritten
  end

  private

  attr_reader :bullets, :job_description_text, :chat

  def prompt
    <<~PROMPT
      #{INSTRUCTIONS}

      Job description:
      #{job_description_text}

      Original bullets:
      #{bullets.map.with_index(1) { |bullet, index| "#{index}. #{bullet}" }.join("\n")}
    PROMPT
  end
end
