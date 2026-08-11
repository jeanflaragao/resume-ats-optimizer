# LLM call that rephrases a resume's existing bullets to pick up a job
# posting's terminology/keywords, without adding anything not already true of
# the original bullet. Pairs with Comparison (deterministic) rather than
# replacing it — this only rewords, it never decides what's a match. The
# prompt alone isn't trusted: each rewritten bullet is checked with
# FidelityCheck against its own original (only), and any bullet that fails
# falls back to its original wording rather than risking invented content.
class BulletRewriter
  include RedactedTokenHint
  class MismatchedBulletCountError < StandardError; end

  # #call returns Array<Rewrite> rather than two parallel arrays (bullet
  # text + fallback flags): a single struct per bullet can't have its text
  # desync from its own fell_back flag the way two independently-returned
  # arrays could. Resume::Optimization::Experience (issue #117) splits this
  # into its own bullets:/bullet_fallbacks: pair, since Resume::Pdf's
  # contract needs bullets to stay Array<String>.
  Rewrite = Data.define(:text, :fell_back)

  FIDELITY_MIN_TOKEN_COVERAGE = FidelityCheck::DEFAULT_MIN_TOKEN_COVERAGE

  # Identifies "the rewrite this code produces" for Resume::CachedOptimization's
  # key (issue #83), so a cached rewrite is never served after the thing that
  # produced it has changed. Two signals, because each covers the other's blind
  # spot:
  #
  # - PROMPT_VERSION is hand-bumped, and catches what a digest of the text
  #   cannot see -- FIDELITY_MIN_TOKEN_COVERAGE, the order #prompt assembles
  #   its sections in, anything about how the reply is post-processed.
  # - The INSTRUCTIONS digest catches the case the hand-bump exists to cover
  #   and someone forgets.
  #
  # Bump PROMPT_VERSION whenever a change alters what a rewrite means but
  # leaves INSTRUCTIONS byte-identical. Getting it wrong is bounded: stale
  # rewrites are served for at most Resume::CachedOptimization::CACHE_TTL.
  PROMPT_VERSION = 1

  def self.prompt_fingerprint
    "#{PROMPT_VERSION}-#{Digest::SHA256.hexdigest(INSTRUCTIONS).first(12)}"
  end

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

  def self.call(bullets:, job_description_text:, chat:)
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
    return Rewrite.new(text: candidate, fell_back: false) if result.passed

    Rails.logger.warn(
      "BulletRewriter: bullet #{index + 1} failed fidelity check " \
      "(unverifiable: #{redacted_token_hint(result.unverifiable_tokens)}); using original wording instead."
    )
    Rewrite.new(text: original, fell_back: true)
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
