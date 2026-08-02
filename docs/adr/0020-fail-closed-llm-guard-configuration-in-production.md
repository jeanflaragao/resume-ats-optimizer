# ADR-0020: Refuse to boot production on LlmCallGuard's local-testing defaults

## Status
Accepted

## Context

`LlmCallGuard` reads two environment variables, both with defaults chosen for local safety
(`llm_call_guard.rb`):

```ruby
ActiveModel::Type::Boolean.new.cast(ENV.fetch("ENABLE_REAL_LLM_CALLS", "false"))
Integer(ENV.fetch("MAX_LLM_CALLS_PER_DAY", "10"))
```

Nothing outside `docker-compose.yml` (local-only by its own header) and `.env.example` sets
either. `config/deploy.yml` and `.kamal/` do not exist — that is issue #48. So the first
production deploy inherits both defaults, and a third variable behaves the same way:
`config/initializers/ruby_llm.rb:4` reads `ANTHROPIC_API_KEY` with a bare `ENV[]`, which is
`nil`-tolerant.

All three failures share a shape: **the app boots cleanly and the damage appears in a user's
output.**

1. `ENABLE_REAL_LLM_CALLS` unset → every call site gets `StubChat`, whose `STUB_LABEL` is
   written into the summary, the extracted job title, and *every* rewritten bullet. Those go
   into a real, downloadable PDF. Nothing in the app treated stub mode as an error state or
   surfaced it in the UI; the label buried in the output was the only signal.
2. `MAX_LLM_CALLS_PER_DAY` unset → the whole service shares a ceiling of 10. Since ADR-0019
   made the counter accurate at the provider boundary, 10 means 10 real requests. One full
   user flow — upload, analyze, preview, download — costs `2 + 2E` requests, where `E` is the
   number of experiences with bullets:

   | Stage | Call site | Requests |
   |---|---|---|
   | Upload | `resume/extractors/llm.rb` | 1 |
   | Analyze | `job_description/extractor.rb` | 1 |
   | Preview | `resume/optimization.rb` → `bullet_rewriter.rb`, once per experience | E |
   | Download | the same pipeline again (#83) | E |

   That is 12 requests for a 5-experience resume and 20 for a 9-experience one. A single
   ordinary user exhausts the day, and because the counter has no per-user dimension (#45),
   every other visitor then sees *"We've hit today's processing limit."*
3. `ANTHROPIC_API_KEY` unset while real calls are enabled → nothing fails until the first
   user's upload, which surfaces as *"The AI service is temporarily unavailable."*

Before ADR-0019, the second failure was hidden by the first: the counter moved once per flow,
so the cap was permissive by accident. Fixing the counter made it restrictive by accident. The
number was never chosen against real request volume, because until then real request volume
could not be observed. Neither reading of the default was a decision.

## Decision

**In production, none of these variables has a default. The app refuses to finish booting until
each is set explicitly.** `LlmCallGuard.validate_configuration!` enforces four rules, called
from `config/initializers/llm_call_guard.rb`:

1. `ENABLE_REAL_LLM_CALLS` must be present.
2. If it casts false, `ALLOW_STUB_LLM=true` must also be present. Stub mode in production is a
   deliberate, separately-confirmed choice, never something a deploy falls into.
3. `ANTHROPIC_API_KEY` must be present and non-blank whenever real calls are enabled.
4. `MAX_LLM_CALLS_PER_DAY` must be present and parse as a positive `Integer`.

Development and test are untouched: stub mode and a cap of 10 remain the correct local state.

Four supporting decisions:

- **No production number lives in code.** The cap is a spend decision, sized from `2 + 2E`,
  and it belongs in the deploy config (#48). Writing a "sensible production default" would
  reintroduce exactly the defect this ADR closes. `.env.example` documents the sizing formula
  instead of a value.
- **The cap is required even when stub mode is allowed**, where it is never read. This makes
  turning `ALLOW_STUB_LLM` off a one-variable change that cannot half-fail, and keeps the
  production rule statable in one sentence.
- **Allowed stub mode is visible in the UI**, not only in the generated output. A "Demo mode"
  banner renders in the layout whenever `LlmCallGuard.stub_mode_banner?` — stub mode outside
  `Rails.env.local?`. The predicate is split from `stub_mode?` so "are we stubbing" and "should
  the UI say so" stay separable, but it derives from `enabled?`, so it cannot diverge from the
  gating decision it reports.
- **The check runs in `config.to_prepare`, guarded by `Rails.env.production?`.** `LlmCallGuard`
  lives in `app/services` and is autoloadable; referencing an autoloadable constant during
  initialization is unsupported under Zeitwerk, and `to_prepare` blocks run inside
  `Rails.application.initialize!`, so raising there still aborts boot.

  The env guard is about *loading*, not validating — `validate_configuration!` checks the
  environment itself and no-ops outside production either way. Referencing the constant
  unguarded autoloads the file during boot in every environment, and a file loaded before
  `ActiveSupport::Testing::Parallelization` forks is inherited already-loaded by every worker,
  so SimpleCov never instruments it and reports the whole file as 0% covered. Measured on this
  branch: **88.25% overall unguarded vs 98.70% guarded, with identical tests**, against a
  `minimum_coverage 90` gate. Two alternatives were rejected: filtering the file out of
  SimpleCov (removes one of the app's more critical files from the gate) and lowering the
  threshold (weakens it globally to work around one artifact). Thread-based `parallelize`
  removes the fork, but segfaults Ruby on this suite.

- **Boot behaviour is verified by booting production in a subprocess**, not by an in-process
  flag (`test/config/llm_call_guard_boot_test.rb`). The env guard means the check never runs
  during a normal test boot, so the suite must go look: three cases boot a real production
  environment via `bin/rails runner` and assert it refuses with nothing configured, refuses in
  stub mode without `ALLOW_STUB_LLM`, and starts normally when fully configured. The third is
  the counterweight — without it the first two would pass against an app that could not boot
  production for any unrelated reason. Deleting the initializer's call makes the suite print
  `BOOTED-OK` where a refusal belongs, which is issue #84's failure mode caught directly rather
  than by proxy.

### The one exemption

`Dockerfile:23` sets `RAILS_ENV="production"`, and `Dockerfile:50` boots Rails inside the image
build:

```dockerfile
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile
```

That task loads initializers by two independent paths — propshaft's `task precompile:
:environment` and tailwindcss-rails' `task build: [:environment, :engines]`, which enhances
`assets:precompile`. No deploy-time environment exists at image-build time, and the build
issues no LLM requests, so there is nothing to validate.

The exemption is `ENV.key?("SECRET_KEY_BASE_DUMMY")` and nothing else. It is one variable wide,
Rails' own documented marker for this exact boot (`rails/application.rb`), and already present
on the line in question. It is deliberately *not* a rescue, a `RAILS_ENV`-shaped heuristic, or
a check for "are we in a container" — each of those would also exempt real deploys.

Every other production entrypoint is validated, including ones that never serve a request:
`bin/docker-entrypoint`'s `db:prepare` (same container and environment as the server that
follows it) and `bin/jobs`, the Solid Queue supervisor, which runs `Resume::OptimizedPdfJob`
and therefore issues real LLM requests.

## Consequences

- A misconfigured deploy fails at boot, loudly, instead of serving placeholder resumes or
  turning every visitor away after the first one. Under Kamal a failed boot is a failed
  deploy, so the previous container keeps serving.
- `rails console` and `rails runner` in production also require the full set. Under Kamal every
  role inherits the same `env:` block, so this is a correct signal rather than friction.
- Acceptance criterion 3 of issue #77 asked for these to be documented "wherever #48 records
  required deploy environment". #48 has no deploy config yet, so they are documented in
  `.env.example`, here, and in `CLAUDE.md` instead, plus a comment on #48's own env-var table.
- This does not make the global cap correct — only deliberate. A single shared ceiling is
  acceptable while access is invite-only; opening signup needs #22's per-user limiting first
  (#45).
- `ENABLE_REAL_LLM_CALLS`'s default of `false` and `MAX_LLM_CALLS_PER_DAY`'s default of `10`
  remain in the code, now reachable only outside production. Keeping them is what leaves local
  development unchanged.
