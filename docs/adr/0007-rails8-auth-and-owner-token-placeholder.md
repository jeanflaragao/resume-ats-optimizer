# ADR-0007: Use Rails 8's built-in auth generator (not Devise), with a temporary owner_token placeholder

## Status
Accepted

## Context
The product needs to scope resumes to the person who uploaded them (multi-user, hosted). Real
authentication (issue #1's roadmap) was scoped as a later phase, but issue #15 ("Build LinkedIn
export upload form") needed *some* way to scope a resume to its owner immediately — the app's
first controller/routes/views, and its `show` action needed to 404 for resumes belonging to
someone else, before real auth existed to build that on top of.

## Decision
Two related decisions:
1. **Auth mechanism (future)**: use Rails 8's built-in authentication generator
   (`bin/rails generate authentication`) rather than Devise, decided as part of issue #1's
   architecture proposal — no extra gem, current "modern Rails" default, sufficient for
   email/password login at this project's scale.
2. **Interim placeholder (now)**: until that lands, `Resume` has a nullable `owner_token:string`
   column (indexed) instead of a `user_id` FK, populated by
   `ApplicationController#current_owner_token` — an opaque per-browser-session token
   (`session[:owner_token] ||= SecureRandom.hex(32)`). `ResumesController#show` (and later,
   `ApplicationController#find_owned_resume!`, extracted in issue #16) scope lookups by it.
   Service-object/console usage that creates a `Resume` with no HTTP session context (tests,
   `Resume::Import` called directly) leaves it `nil`, which is fine — it's only enforced at the
   controller layer.

## Alternatives considered
- **Devise**: more established, more built-in features (password reset flows, confirmable,
  etc.), but issue #1 rejected it in favor of the Rails 8 generator specifically because the
  generator is now the framework default and this project doesn't need Devise's larger feature
  surface for a simple email/password login.
- **Building real auth immediately, ahead of issue #15's actual need**: rejected — issue #15 only
  needed *some* scoping mechanism to ship its upload/show flow; building full auth as a
  prerequisite would have blocked frontend progress on a phase of work (Phase 6/auth) not yet
  reached. The `owner_token` placeholder was accepted specifically as a deliberately temporary,
  narrower stand-in.
- **No scoping at all until real auth lands**: rejected — issue #15's `show` action needed
  *some* way to prevent one browser session from viewing another's uploaded resume, even as a
  placeholder; shipping with zero scoping was judged worse than a known-temporary token scheme.

## Consequences
- `owner_token` is explicitly documented (in this repo's Project Layout notes) as not meant to
  be permanent — it is expected to be replaced with a real `user_id` FK once the Rails 8 auth
  generator lands, at which point `current_owner_token`-based scoping should be replaced
  throughout, not layered underneath real auth.
- Every controller reading resume data (`ResumesController`, and via `find_owned_resume!`:
  `JobDescriptionsController`, `PreviewsController`, `DownloadsController`) currently depends on
  this placeholder; auth work will need to touch all of them, not just add a login screen.
- Because the token lives in the session and not tied to any verified identity, it provides
  session-scoping, not real authentication or authorization — anyone who can read a given
  browser's session (or has it shared/synced) can access resumes created under it. Acceptable
  for the current pre-auth phase, not acceptable as a permanent security model.
