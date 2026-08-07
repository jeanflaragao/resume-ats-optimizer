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
| 0007 | Use Rails 8's built-in auth generator (not Devise), with a temporary owner_token placeholder | Superseded by 0032 | [0007-rails8-auth-and-owner-token-placeholder.md](0007-rails8-auth-and-owner-token-placeholder.md) |
| 0008 | Make the repository public to unlock branch protection and secret scanning | Accepted | [0008-public-repo-for-branch-protection.md](0008-public-repo-for-branch-protection.md) |
| 0009 | Configure Dependabot for automatic version-update PRs, not just vulnerability alerts | Accepted | [0009-dependabot-automatic-version-prs.md](0009-dependabot-automatic-version-prs.md) |
| 0010 | Accept `data: { turbo: false }` as a stopgap for POST-rendering controllers | Superseded by 0014 | [0010-turbo-drive-stopgap-data-turbo-false.md](0010-turbo-drive-stopgap-data-turbo-false.md) |
| 0011 | Drop unused ActiveStorage/ActionText/ActionMailbox from the dependency tree | Accepted | [0011-drop-unused-active-storage-action-text-mailbox.md](0011-drop-unused-active-storage-action-text-mailbox.md) |
| 0012 | Wire Solid Cache as the production cache store | Accepted | [0012-wire-solid-cache-as-production-cache-store.md](0012-wire-solid-cache-as-production-cache-store.md) |
| 0013 | Enable CSRF forgery protection for system tests only | Accepted | [0013-enable-forgery-protection-in-system-tests.md](0013-enable-forgery-protection-in-system-tests.md) |
| 0014 | Convert JobDescriptions/Previews/Downloads to turbo_stream responses | Accepted | [0014-convert-post-controllers-to-turbo-stream-responses.md](0014-convert-post-controllers-to-turbo-stream-responses.md) |
| 0015 | Treat every extracted resume field as personal data; redact all values from log output | Accepted | [0015-uniform-log-redaction-for-resume-fields.md](0015-uniform-log-redaction-for-resume-fields.md) |
| 0016 | Named rescue list for domain errors — rescue_from for LLM errors, controller-level rescue for file-parsing errors | Accepted | [0016-named-rescue-list-for-domain-errors.md](0016-named-rescue-list-for-domain-errors.md) |
| 0017 | Bound upload size and job description length | Accepted | [0017-bound-upload-size-and-job-description-length.md](0017-bound-upload-size-and-job-description-length.md) |
| 0018 | Embed Liberation Sans with a DejaVu Sans fallback, and refuse to render scripts no font covers | Accepted | [0018-embed-liberation-sans-with-dejavu-fallback.md](0018-embed-liberation-sans-with-dejavu-fallback.md) |
| 0019 | Count LLM calls at the provider-call boundary, and fail closed when the count is unavailable | Accepted | [0019-count-llm-calls-at-the-provider-boundary.md](0019-count-llm-calls-at-the-provider-boundary.md) |
| 0020 | Refuse to boot production on LlmCallGuard's local-testing defaults | Accepted | [0020-fail-closed-llm-guard-configuration-in-production.md](0020-fail-closed-llm-guard-configuration-in-production.md) |
| 0021 | Cache the optimization result between preview and download, keyed by a job-description digest | Accepted | [0021-cache-the-optimization-result-between-preview-and-download.md](0021-cache-the-optimization-result-between-preview-and-download.md) |
| 0022 | Pass the download job a job-description reference, not the text | Accepted | [0022-job-description-reference-instead-of-queue-argument.md](0022-job-description-reference-instead-of-queue-argument.md) |
| 0023 | Per-session usage quotas in Postgres, alongside (not instead of) the global LLM cap | Superseded by 0033 | [0023-per-session-usage-quotas-in-postgres.md](0023-per-session-usage-quotas-in-postgres.md) |
| 0024 | Add a CJK fallback font, and refuse scripts requiring text shaping even when glyphs exist | Accepted | [0024-refuse-scripts-requiring-shaping.md](0024-refuse-scripts-requiring-shaping.md) |
| 0025 | Check PDF renderability before spending quota, and resolve fallback fonts lazily | Accepted | [0025-check-renderability-before-spending-quota.md](0025-check-renderability-before-spending-quota.md) |
| 0026 | Purge stale resumes with owner-scoped retention | Superseded by 0034 | [0026-purge-stale-resumes.md](0026-purge-stale-resumes.md) |
| 0027 | Disable Turbo's progress bar rather than widen style-src | Accepted | [0027-disable-turbo-progress-bar-for-csp.md](0027-disable-turbo-progress-bar-for-csp.md) |
| 0028 | Deploy to Railway now; keep Kamal as the documented path to AWS later | Accepted | [0028-deploy-to-railway-not-kamal.md](0028-deploy-to-railway-not-kamal.md) |
| 0029 | Redirect `DownloadsController#create` to an addressable `/downloads/:id` | Accepted | [0029-redirect-downloads-to-an-addressable-url.md](0029-redirect-downloads-to-an-addressable-url.md) |
| 0030 | Converge `DownloadsController#ready` on `204 No Content` for an owner mismatch | Accepted | [0030-converge-ready-on-no-content-for-owner-mismatch.md](0030-converge-ready-on-no-content-for-owner-mismatch.md) |
| 0031 | Persist discarded resume data as pending items, and never prefill a possibly-fabricated one | Accepted | [0031-surface-discarded-resume-data.md](0031-surface-discarded-resume-data.md) |
| 0032 | Google OAuth authentication, superseding the Rails 8 auth generator plan | Accepted | [0032-google-oauth-authentication.md](0032-google-oauth-authentication.md) |
| 0033 | Key Usage::Quota's subject on the signed-in user, not the session | Accepted | [0033-user-id-usage-quotas.md](0033-user-id-usage-quotas.md) |
| 0034 | One month from last access, single-tier, credits never purged | Accepted | [0034-one-month-user-scoped-retention.md](0034-one-month-user-scoped-retention.md) |
