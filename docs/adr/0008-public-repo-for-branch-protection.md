# ADR-0008: Make the repository public to unlock branch protection and secret scanning

## Status
Accepted

## Context
Issue #46 ("Set up repository best practices and security configuration") required branch
protection on `master` (required status checks, no direct pushes, no owner bypass) and secret
scanning + push protection. The repository was private at the time. Both features were attempted
against the private repo first.

## Decision
Make the repository public, after first verifying git history was clean (no `.env`, no
`master.key`, no committed credentials — confirmed via history search; `.env` had always been
gitignored per this project's Local development conventions). This unlocked both branch
protection and secret scanning/push protection, which were then configured and independently
re-verified with a fresh `gh api` read after each change (not just trusted from the mutating
call's own response — the `secret_scanning_push_protection` PATCH once returned 200 with the
field still showing `disabled` in its own response body, which is exactly the kind of
silent-failure this re-verification step was meant to catch).

## Alternatives considered
- **GitHub Pro/Team (paid tier) to keep the repo private**: both GitHub's classic branch
  protection API and the newer Rulesets API were tried against the private repo first, and both
  returned "Upgrade to GitHub Pro or make this repository public" — confirming there is no free
  path to these features on a private repo. Secret scanning + push protection are part of GitHub
  Advanced Security, also gated behind a paid tier for private repos. A paid plan was not pursued
  for this solo/low-budget project; going public was the zero-cost option once history was
  confirmed clean.
- **Skip branch protection / secret scanning entirely**: rejected — issue #46 treats these as
  required repository security baseline, not optional hardening, for a project that will
  eventually handle real user resume data and an Anthropic API key.

## Consequences
- All source code, issue history, and commit history are now publicly visible. This was accepted
  only after confirming no secrets exist in git history; ongoing vigilance is still required for
  every future commit (the `.gitignore` `/.env*` rule with the `!/.env.example` exception remains
  the primary safeguard).
- Branch protection now requires all four CI job names (`test`, `lint`, `scan_ruby`, `scan_js`)
  to pass, `strict` mode (branches must be up to date before merging), and `enforce_admins`
  (no bypass, including for the repo owner) — meaning even the maintainer cannot force-merge
  around a failing check without first disabling protection.
- Vulnerability alerts and Dependabot's automatic PRs (ADR-0009) both depend on this same
  public-repo/security-configuration change, and directly led to discovering the ActiveStorage
  CVE that motivated ADR-0011.
