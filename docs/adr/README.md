# Architecture Decision Records

This directory records the significant architectural decisions made in resume-ats-optimizer, in
[Michael Nygard's ADR format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).
Each ADR captures a decision at the point it was made — alternatives considered, trade-offs
accepted — and is not rewritten as the app evolves. For the current, living description of the
stack and architecture, see [`CLAUDE.md`](../../CLAUDE.md) at the repo root.

| # | Title | Status | Link |
|---|-------|--------|------|
| 0001 | Use a Rails 8 Hotwire monolith instead of a separate API + SPA frontend | Accepted | [0001-rails-8-hotwire-monolith.md](0001-rails-8-hotwire-monolith.md) |
| 0002 | Use Rails 8's Solid Queue/Cache/Cable instead of Redis | Accepted | [0002-solid-trio-instead-of-redis.md](0002-solid-trio-instead-of-redis.md) |
| 0003 | Use RubyLLM instead of a thin API wrapper (ruby-anthropic) for LLM calls | Accepted | [0003-rubyllm-as-llm-client.md](0003-rubyllm-as-llm-client.md) |
| 0004 | Use Prawn instead of Grover/Puppeteer for PDF generation | Accepted | [0004-prawn-for-pdf-generation.md](0004-prawn-for-pdf-generation.md) |
| 0005 | Support two selectable resume-extraction strategies (LLM + deterministic) | Accepted | [0005-dual-resume-extraction-strategy.md](0005-dual-resume-extraction-strategy.md) |
| 0006 | Keep comparison/scoring logic strictly deterministic and verify all LLM output with FidelityCheck | Accepted | [0006-deterministic-llm-separation-and-fidelitycheck.md](0006-deterministic-llm-separation-and-fidelitycheck.md) |
| 0007 | Use Rails 8's built-in auth generator (not Devise), with a temporary owner_token placeholder | Accepted | [0007-rails8-auth-and-owner-token-placeholder.md](0007-rails8-auth-and-owner-token-placeholder.md) |
| 0008 | Make the repository public to unlock branch protection and secret scanning | Accepted | [0008-public-repo-for-branch-protection.md](0008-public-repo-for-branch-protection.md) |
| 0009 | Configure Dependabot for automatic version-update PRs, not just vulnerability alerts | Accepted | [0009-dependabot-automatic-version-prs.md](0009-dependabot-automatic-version-prs.md) |
| 0010 | Accept `data: { turbo: false }` as a stopgap for POST-rendering controllers | Accepted | [0010-turbo-drive-stopgap-data-turbo-false.md](0010-turbo-drive-stopgap-data-turbo-false.md) |
| 0011 | Drop unused ActiveStorage/ActionText/ActionMailbox from the dependency tree | Accepted | [0011-drop-unused-active-storage-action-text-mailbox.md](0011-drop-unused-active-storage-action-text-mailbox.md) |
