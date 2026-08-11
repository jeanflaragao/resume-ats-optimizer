#!/usr/bin/env bash
# PreToolUse hook for the standards-reviewer subagent (.claude/agents/standards-reviewer.md,
# issue #20). This script IS the read-only guarantee -- the subagent's tools: list grants Bash
# unrestricted shell access, and its system prompt telling it not to mutate anything is
# defense-in-depth, not enforcement. Everything not explicitly allowlisted here is blocked,
# including a command a prompt-injection attempt embedded in a reviewed PR's own description
# might try to talk the subagent into running.
set -euo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"

if [ -z "$command" ]; then
  echo "Blocked: read-only subagent, no command found in tool input." >&2
  exit 2
fi

# Reject chaining/redirection/substitution outright -- none of the allowed commands below need
# them, and allowing any would let an otherwise-matching prefix smuggle a second command past the
# allowlist (e.g. "git log && rm -rf ."). Bash glob matching (case), not grep -E: grep -E's "\n"
# is not portably "newline" -- on this image it matched a literal "n", silently turning this check
# into "block any command containing the letter n," which is nearly all of them. Verified by
# testing the block in isolation; case/[[ ]] tests bytes directly with no regex-escape ambiguity.
case "$command" in
  *';'*|*'&'*|*'|'*|*'`'*|*'$('*|*'>'*|*'<'*)
    echo "Blocked: read-only subagent, command contains chaining/redirection/substitution: $command" >&2
    exit 2
    ;;
esac
if [[ "$command" == *$'\n'* ]]; then
  echo "Blocked: read-only subagent, command contains an embedded newline: $command" >&2
  exit 2
fi

# Reject a leading env-var assignment on any command (e.g. "ENABLE_REAL_LLM_CALLS=true docker
# compose run ..."), which could smuggle real API calls into a "read-only" review.
if printf '%s' "$command" | grep -qE '^[A-Za-z_][A-Za-z0-9_]*='; then
  echo "Blocked: read-only subagent, command starts with an env-var assignment: $command" >&2
  exit 2
fi

allowed=false

# git: read-only history/state inspection only.
if printf '%s' "$command" | grep -qE '^git (diff|log|show|status|blame)( |$)'; then
  allowed=true
fi

# gh: read-only PR/issue inspection only -- no create/comment/close/edit.
if printf '%s' "$command" | grep -qE '^gh (pr (view|diff|list)|issue (view|list))( |$)'; then
  allowed=true
fi

# The project's four CI-required gates (.github/workflows/ci.yml), run exactly as CI runs them --
# no "-e" flag, so an env var can't be smuggled in that way either.
if printf '%s' "$command" | grep -qE '^docker compose run --rm web bin/(rails test|rubocop|brakeman|importmap audit)( |$)' \
  && ! printf '%s' "$command" | grep -qE ' -e '; then
  allowed=true
fi

if [ "$allowed" = true ]; then
  exit 0
fi

echo "Blocked: read-only subagent, command not on the allowlist: $command" >&2
exit 2
