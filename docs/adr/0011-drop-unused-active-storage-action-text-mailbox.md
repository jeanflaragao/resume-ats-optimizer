# ADR-0011: Drop unused ActiveStorage/ActionText/ActionMailbox from the dependency tree

## Status
Accepted

## Context
Dependabot's vulnerability-alerts feature (enabled as part of issue #46 / ADR-0008-0009) flagged
a critical CVE in `activestorage` — arbitrary file read / RCE in variant processing. Issue #52
investigated whether a Rails point-release bump (patches the CVE, keeps the gem) or dropping the
gem entirely (removes the attack surface) was the right response. The investigation found:
- `activestorage` is pulled in only as a transitive, forced dependency of `gem "rails"`, loaded
  via `require "rails/all"` in `config/application.rb` — never a direct Gemfile entry, never a
  selective require.
- No app code uses it: no `has_one_attached`/`has_many_attached`, no `ActiveStorage::Blob`
  references anywhere in `app/`. `image_processing` (needed for real variant processing) is
  commented out in the Gemfile, confirming variants were never actually set up — consistent with
  this project's existing "no Active Storage" stance (uploaded files are consumed directly at
  import time, per issue #15, never persisted via Active Storage).
- **Despite being unused, its routes are mounted and reachable regardless** —
  `bin/rails routes` shows `/rails/active_storage/blobs/...`,
  `/rails/active_storage/representations/...` (the exact variant-processing path the CVE is in),
  and `/rails/active_storage/direct_uploads`, because `rails/all` auto-mounts the engine whether
  or not the app calls its APIs. This is real, currently-reachable attack surface for a feature
  that is never used, not merely an idle library sitting in the gem cache.
- `ActionText` and `ActionMailbox` are equally unused (zero references in `app/` or `config/`).
  `ActionMailer` has only the empty `ApplicationMailer` scaffold stub today, but is expected to
  be needed once real auth (password-reset emails, per ADR-0007's Rails 8 auth generator plan)
  is built.

## Decision
Drop `ActiveStorage`, `ActionText`, and `ActionMailbox` entirely, rather than only bumping Rails
to patch the one flagged CVE: replace `require "rails/all"` in `config/application.rb` with
selective railtie requires (keep `active_record/railtie`, `action_controller/railtie`,
`action_view/railtie`, `active_job/railtie`, `action_cable/engine`, `action_mailer/railtie`; drop
`active_storage/engine`, `action_text/engine`, `action_mailbox/engine`), swap `gem "rails"` for
the specific framework gems actually needed so the three unused gems stop being resolved into
`Gemfile.lock` at all, and clean up now-dead config (`config.active_storage.service` per
environment, `config/storage.yml`). This is Rails' documented "modular Rails" pattern (what
`rails new --minimal` generates from scratch), applied retroactively. `ActionMailer` is kept.

**Note**: as of this writing, issue #52 is still open — this ADR records the decision and its
investigated rationale, not a completed migration. `config/application.rb` still contains
`require "rails/all"`.

## Alternatives considered
- **Patch-bump Rails to the fixed point release, keep `rails/all`**: clears the specific flagged
  CVE with minimal, low-risk change (no framework-composition surgery). Accepted as a valid
  *interim* mitigation if the alert needs clearing faster than the full removal gets scheduled,
  but explicitly rejected as the final fix — it leaves the same class of problem in place
  (unused frameworks with auto-mounted, reachable routes) for the *next* CVE in ActiveStorage,
  ActionText, or ActionMailbox to repeat this exact incident.
- **Leave ActiveStorage/ActionText/ActionMailbox in place indefinitely, accept the alert as
  noise**: rejected — the investigation confirmed this isn't just an unused-dependency hygiene
  issue but a real, reachable attack surface (working routes into the exact vulnerable code
  path), which this project's general security posture (ADR-0008's branch protection, secret
  scanning) argues against tolerating.
- **Drop ActionMailer along with the other three**: considered and rejected — unlike the other
  three, ActionMailer is anticipated to be needed shortly (password-reset emails once ADR-0007's
  real auth generator is implemented), so removing it now would likely mean re-adding it again
  soon.

## Consequences
- Once implemented, three previously-reachable route namespaces
  (`/rails/active_storage/*`, `/rails/action_text/*` if mounted, `/rails/action_mailbox/*`)
  will no longer exist, eliminating that attack surface entirely rather than just patching the
  currently-known CVE within it.
- `config/application.rb`'s framework composition becomes an explicit allowlist (selective
  railtie requires) rather than "everything Rails ships with" — future framework additions
  (e.g. if Active Storage is genuinely needed later) must be added back deliberately, which is
  the intended trade-off of the modular pattern.
- Requires a full regression run (`bin/rails test`, `bin/rubocop`, manual boot check) once
  implemented, since this touches framework composition on every request path — flagged in
  issue #52 as necessary precisely because the blast radius of getting a railtie removal wrong
  is "the app doesn't boot," not a narrow, contained failure.
- This ADR's implementation is tracked by the still-open issue #52; the decision is accepted,
  the migration is not yet done.
