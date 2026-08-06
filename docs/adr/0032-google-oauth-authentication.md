# ADR-0032: Google OAuth authentication, superseding the Rails 8 auth generator plan

## Status
Accepted

## Context
ADR-0007 accepted `resumes.owner_token` — an opaque per-browser-session cookie value, populated by
`ApplicationController#current_owner_token` — as a deliberately temporary placeholder, and
committed to replacing it with Rails 8's built-in authentication generator
(`bin/rails generate authentication`, email/password with bcrypt) "once real auth exists." Issue
#120 made accounts mandatory instead — no anonymous session may reach the app at all, because every
upload is a real, cost-bearing LLM call that must be attributable and, eventually, payable
(#122/#123). That product decision also replaced the *mechanism*: OAuth, not email/password.

**Verified before this ADR, not assumed**: the Rails 8 authentication generator has no OAuth
support. Read directly from this project's pinned `railties (8.1.3.1)`
(`~> 8.1.3` in `Gemfile.lock`) — its templates generate only a `User` with
`email_address`/`password_digest` (`has_secure_password`), a `Session`, a `Current` singleton, a
password-based `SessionsController`, and a full password-reset mailer flow. Nothing in it talks to
an OAuth provider. Adopting OAuth therefore means the generator itself cannot be run as-is; this
ADR records what replaces it.

## Decision

1. **OAuth via `omniauth` + `omniauth-google-oauth2` + `omniauth-rails_csrf_protection`, not the
   Rails 8 generator.** ADR-0007's original reasoning for preferring the generator over Devise ("no
   extra gem needed") no longer applies once OAuth, not password auth, is the mechanism — OAuth
   requires a client gem regardless of which framework issues the eventual session. The
   generator's *architecture* is still reused (see below); only its password-specific pieces are
   dropped.

2. **Google only for v1, no GitHub.** The original product ask named both. Recorded here as a
   flagged departure, confirmed rather than assumed: GitHub is a poor default identity provider for
   this product's audience. resume-ats-optimizer's users are job seekers, not developers — almost
   no non-technical candidate has a GitHub account, so offering it as a sign-in option would add a
   rarely-used code path without adding real reach. Revisit if usage data ever shows demand.

3. **Identity resolved by verified email, not by `(provider, uid)` alone.** A `User` has many
   `identities` (`provider`, `uid`), even though only `google_oauth2` ships in v1. Deciding this now
   costs one small join table; deciding it after a second provider and real paid balances exist
   would cost a migration and, worse, could silently split one person's paid credits (#122 makes
   credits a permanent, never-expiring liability) across two `User` rows keyed to the same person's
   two logins. `Authentication::FindOrCreateUser` implements this: an existing `Identity` for
   `(provider, uid)` returns its user directly; otherwise a `User` is found-or-created by email
   (rejecting an unverified one) and a new `Identity` is attached.

4. **Architecture mirrors the Rails 8 generator's own shape, minus password auth.** `Current`
   (`ActiveSupport::CurrentAttributes`, delegating `user` from `session`), a DB-backed, revocable
   `Session` record (`belongs_to :user`), and an `Authentication` concern
   (`require_authentication`/`resume_session`/`start_new_session_for`/`terminate_session`) —
   read directly from the generator's templates and reproduced with the credential check swapped
   from `User.authenticate_by` to `Authentication::FindOrCreateUser.call(auth:)` against an OmniAuth
   callback. The DB-backed `Session` (over a bare `session[:user_id]`) is a deliberate choice: it
   costs one small table now and buys real revocability — signing out one device, or all — before
   real users exist to need it retroactively. Dropped entirely: `bcrypt`, `password_digest`,
   `PasswordsController`, the password-reset mailer — none apply to OAuth-only sign-in.

5. **`GOOGLE_OAUTH_CLIENT_ID`/`GOOGLE_OAUTH_CLIENT_SECRET` are ENV vars, validated at boot in
   production, not Rails encrypted credentials.** Every live secret in this app already follows
   this pattern (`ANTHROPIC_API_KEY`, `MAX_LLM_CALLS_PER_DAY`, the four `RATE_LIMIT_*` vars) —
   `config/credentials.yml.enc` is reserved exclusively for Active Record Encryption keys, confirmed
   by grepping every use of `Rails.application.credentials` in the codebase (exactly one, inert,
   commented-out SMTP boilerplate). `Authentication::ConfigGuard.validate_configuration!`, invoked
   from `config/initializers/authentication_config_guard.rb` the same `to_prepare`-guarded way as
   `LlmCallGuard`/`Usage::Quota` (ADR-0020, ADR-0023), refuses to finish booting production without
   both — a missing credential fails the deploy, not the first visitor's sign-in attempt.

6. **No per-environment code branching for the OAuth callback URL.** `omniauth-google-oauth2` builds
   it from the incoming request's own host, so `localhost:3000` in dev and the Railway production
   domain each produce the correct callback URL automatically. The only per-environment difference
   is operator-side: which redirect URIs are registered against one Google Cloud OAuth client (see
   `docs/railway-deploy-runbook.md`).

## Alternatives considered
- **Rails 8's built-in generator, email/password**: rejected — the product decision is OAuth, not
  password auth; ADR-0007's reasoning for preferring the generator over Devise was specific to
  password auth and doesn't transfer.
- **Devise with `omniauthable`**: not reconsidered here — ADR-0007 already rejected Devise for this
  project's scale, and nothing about switching to OAuth changes that; Devise's larger feature
  surface (confirmable, lockable, etc.) remains unneeded.
- **Identity resolved by `(provider, uid)` alone, no email-based `User` lookup**: simpler for v1 —
  a `users` row keyed straight to the OAuth identity, no `identities` table. Rejected: a real person
  who later signs in via a second provider with the same email would get a second `User` row with
  its own, separately-zero credit balance, indistinguishable from a stranger. That failure mode is
  a support and money problem once #122 lands, not just an annoyance, and cheap to avoid now.
- **A bare `session[:user_id]` instead of a DB-backed `Session` record**: cheaper — no new table,
  matches how `owner_token` already works. Rejected in favor of matching the Rails 8 generator's own
  architecture, which ADR-0007 already anchored this project on, and for the real revocability it
  buys before real users exist to need it retroactively.

## Consequences
- `resumes.owner_token`-based scoping (ADR-0007) is **not** touched or removed by this ADR.
  `current_owner_token`, `find_owned_resume!`, and `enforce_quota!` in `ApplicationController` are
  unchanged. A signed-in user's resumes remain scoped by their random per-browser `owner_token`
  cookie, not by their real `user_id`, until #121 migrates ownership — two scoping mechanisms
  coexist deliberately in the interim, not a bug to fix here.
- Every controller action in the app now requires a signed-in `User` by default
  (`before_action :require_authentication`), with `allow_unauthenticated_access` opted into only by
  `SessionsController#new/create/failure`. This is a new, real local-development requirement: an
  operator must register their own Google OAuth client (`docs/railway-deploy-runbook.md`) before
  they can sign in even locally — there is no stub/offline sign-in path, unlike `LlmCallGuard`'s
  stub mode for LLM calls, because real testers need a real Google sign-in to exercise.
- A new gem dependency (`omniauth`, `omniauth-google-oauth2`, `omniauth-rails_csrf_protection`) this
  project did not previously need, and would not have needed under the generator's original
  email/password plan.
- This supersedes ADR-0007's Rails-8-generator plan for the eventual real-auth mechanism; its
  Status now points here. ADR-0007's `owner_token` placeholder itself remains accurately described
  by ADR-0007 until #121 replaces it — that migration is #121's ADR to write, not this one's.
