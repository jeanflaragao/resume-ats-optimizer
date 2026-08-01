# Shared formatting for fidelity-check token lists logged on a drop/fallback.
#
# Sorts tokens (removing positional information that could reconstruct ordered
# prose) and caps at MAX_TOKENS with an overflow marker, so the log line stays
# diagnostically useful without leaking the original text.
module RedactedTokenHint
  MAX_TOKENS = 5

  def redacted_token_hint(tokens)
    sorted = tokens.sort
    shown  = sorted.first(MAX_TOKENS)
    rest   = sorted.size - shown.size
    rest > 0 ? "#{shown.join(', ')} (+#{rest} more)" : shown.join(", ")
  end
end
