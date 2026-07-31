# LLM call that rephrases a resume's existing bullets to pick up a job
# posting's terminology/keywords, without adding anything not already true of
# the original bullet. Pairs with Comparison (deterministic) rather than
# replacing it — this only rewords, it never decides what's a match. The
# prompt alone isn't trusted: each rewritten bullet is checked with
# FidelityCheck against its own original (only), and any bullet that fails
# falls back to its original wording rather than risking invented content.
class BulletRewriter
  class MismatchedBulletCountError < StandardError; end

  FIDELITY_MIN_TOKEN_COVERAGE = FidelityCheck::DEFAULT_MIN_TOKEN_COVERAGE

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

    bullets.zip(rewritten).map.with_index { |(original, candidate), index| verify(original, candidate, index) }
  end

  private

  attr_reader :bullets, :job_description_text, :chat

  # Falls back to the original bullet (guaranteed-safe, real user data) rather
  # than raising — a content-fidelity failure on one bullet always has an
  # obvious, safe 1:1 recovery, unlike a bullet-count mismatch.
  def verify(original, candidate, index)
    result = FidelityCheck.call(
      candidate_text: candidate,
      source_text: original,
      min_token_coverage: FIDELITY_MIN_TOKEN_COVERAGE
    )
    return candidate if result.passed

    Rails.logger.warn(
      "BulletRewriter: bullet #{index + 1} failed fidelity check " \
      "(unverifiable: #{result.unverifiable_tokens.join(', ')}); using original wording instead."
    )
    original
  end

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
