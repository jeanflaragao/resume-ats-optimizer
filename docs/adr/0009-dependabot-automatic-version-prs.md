# ADR-0009: Configure Dependabot for automatic version-update PRs, not just vulnerability alerts

## Status
Accepted

## Context
Issue #46's original checklist scoped Dependabot narrowly — "security alerts (not automatic
version-update PRs)". While implementing repository security configuration end-to-end, the
narrower passive-alerts-only setup was reconsidered against the cost of leaving dependencies
(Ruby gems and GitHub Actions) to drift unpatched between manual reviews.

## Decision
Configure `.github/dependabot.yml` for automatic version-update PRs — not just passive
vulnerability alerts — for both `bundler` and `github-actions` ecosystems: daily checks, up to
10 open PRs per ecosystem. Vulnerability alerts remain separately enabled as a distinct
repo-level toggle (confirmed via `GET /repos/:owner/:repo/vulnerability-alerts` → `204`), which
governs security-relevant notifications independent of `dependabot.yml`'s general version-bump
PR behavior.

## Alternatives considered
- **Vulnerability alerts only, no automatic version-bump PRs** (the issue's original, narrower
  scope): lower noise (no routine PRs to review), but leaves the maintainer relying on manually
  noticing and acting on alerts, and leaves non-security dependency drift (outdated but not yet
  flagged-vulnerable gems) entirely unaddressed until a human looks. Superseded in favor of
  automatic PRs once branch protection (ADR-0008) was already in place to gate them through CI
  before merge, making the added PR volume a manageable, checked-by-CI cost rather than
  unreviewed risk.
- **Renovate or another dependency-update bot**: not evaluated — Dependabot is GitHub-native,
  required no additional integration setup, and was already scaffolded (config file present)
  from the initial project scaffold.

## Consequences
- Every dependency bump (gem or Action) now arrives as its own PR, gated by the same branch
  protection required-checks configuration from ADR-0008 — a bump can't merge without passing
  `test`, `lint`, `scan_ruby`, and `scan_js`.
- Higher routine PR volume than the originally-scoped alerts-only approach; the 10-open-PR cap
  per ecosystem bounds how much can pile up if PRs aren't triaged promptly.
- The separately-enabled vulnerability-alerts toggle (not this file's version-bump PR config) is
  what actually surfaced the ActiveStorage CVE that motivated issue #52 / ADR-0011 — recorded
  here because both were configured together as part of the same issue #46 security setup.
