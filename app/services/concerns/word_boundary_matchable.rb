# Shared word-boundary text matching for the deterministic (non-LLM) safety
# checks in this codebase (Comparison, FidelityCheck). Word-boundary rather
# than plain substring so a short term like "Go" doesn't false-positive
# against "Google" or "Django".
module WordBoundaryMatchable
  def word_boundary_match?(term, text)
    pattern = /(?<![[:alnum:]])#{Regexp.escape(term.downcase)}(?![[:alnum:]])/
    text.downcase.match?(pattern)
  end
end
