# ADR-0013: Enable CSRF forgery protection for system tests only

## Status
Accepted

## Context
`config/environments/test.rb` sets `config.action_controller.allow_forgery_protection = false`
for the whole test environment. This makes an entire class of bug invisible to every automated
test in the repo: Rails 8's per-form CSRF tokens (`config.load_defaults 8.0`) bind a form's
`authenticity_token` to its own declared `action`, so a `formaction`-overridden submit button —
submitting to a different path than the one its token was generated for — fails verification on
a real (non-Turbo) browser POST. ADR-0010 documents exactly this shape of gap for a related bug
(Turbo Drive rejecting non-`turbo_stream` POST responses): both were real, already-merged bugs in
`resumes/show.html.erb` (issues #16/#17) found only by manually testing against the dev server
during #18, because integration tests run in-process and never render real forms or carry real
tokens, and no system test existed yet either.

By the time issue #57 was filed, the `formaction` bug itself was already fixed (#18 gave the
"Check match" and "Preview optimized resume" buttons separate, correctly-scoped `<form>`s, kept
in sync by `app/javascript/controllers/sync_controller.js`). But the *mechanism* that would catch
a regression — or the next bug of this shape — was still missing: system tests never turned
forgery protection on, so `test/system/resume_downloads_test.rb` would have passed identically
whether the forms were correct or broken. Issue #47 is about to rewrite all three of those
`data: turbo: false` forms into `turbo_stream` responses; #57 closes this gap first, so that
rewrite happens with real CSRF coverage already in place instead of after.

## Decision
Enable forgery protection for system tests only, scoped via `ApplicationSystemTestCase`'s
`setup`/`teardown` rather than the global `config/environments/test.rb` flag:

```ruby
setup do
  @previous_allow_forgery_protection = ActionController::Base.allow_forgery_protection
  ActionController::Base.allow_forgery_protection = true
end

teardown do
  ActionController::Base.allow_forgery_protection = @previous_allow_forgery_protection
end
```

Storing and restoring the prior value (rather than hardcoding `false` in teardown) keeps this
correct if `config/environments/test.rb`'s own default ever changes. `test/test_helper.rb`'s
`parallelize(workers: :number_of_processors)` call uses Rails' default `with: :processes`
executor (confirmed against `activesupport-8.1.3`'s own source), so this global class-attribute
mutation is safe: each parallel worker is a forked OS process with independent memory, and within
a single worker Minitest runs one test at a time, so no other test can observe the flag mid-flip.

Verified the mechanism actually works both ways before relying on it: with today's correct
two-form markup, a system test with protection enabled still passes (real tokens generated and
verified correctly); with the markup deliberately, temporarily reverted to the original
single-form/`formaction` pattern, the same test fails with
`ActionController::InvalidAuthenticityToken in PreviewsController#create` — reproducing the
original #17 bug exactly. The view was reverted back immediately after; no lasting regression
test keeps the buggy pattern around (a regression test for it would need to either keep broken
production code alive to test against, or assert on view/controller internals #47 is about to
rewrite anyway — not worth it here).

Added `test/system/forgery_protection_test.rb`, a minimal, dedicated system test asserting
`ActionController::Base.allow_forgery_protection` directly (no page visit needed), so that
deleting the two-line `setup`/`teardown` mechanism above fails a test instead of silently
reopening this exact gap with the suite staying green — the same silent-safeguard-death failure
mode already hit once for `WordBoundaryMatchable` (issue #55/#63). Kept in its own file, separate
from the business-flow test, so #47's rewrite of the controllers doesn't disturb it.

Also extended `test/system/resume_downloads_test.rb` to submit the "Check match" form (issue #16)
before previewing/downloading — the one form of the three that had no system-test coverage of any
kind until now.

## Alternatives considered
- **Flip `config.action_controller.allow_forgery_protection` globally in
  `config/environments/test.rb`**: rejected outright, per explicit instruction accompanying this
  issue. Integration tests (`ActionDispatch::IntegrationTest`) don't render forms or carry
  tokens; a global flip would fail every `post` in `test/integration/` for no added signal, and
  the fix for that (retrofitting every integration test to carry a real token) would be a much
  larger, riskier change with no corresponding benefit — integration tests were never the layer
  meant to catch this class of bug.

## Consequences
- System tests now exercise real CSRF verification on every real, `data: turbo: false` form
  submission — closing the gap ADR-0010 and CLAUDE.md's Stack section both flagged as an open
  problem. ADR-0010's `## Status` now carries a pointer to this ADR.
- Integration tests remain untokened — by design, not a regression: they still can't (and aren't
  meant to) catch this class of bug. That responsibility now sits entirely with system tests.
- This protects the *mechanism*, not any specific past bug: `forgery_protection_test.rb` asserts
  the flag is on, not that any particular form is correctly scoped. #47's upcoming
  `turbo_stream` rewrite of the three affected controllers will still need its own system-test
  coverage to prove those specific new responses carry/verify tokens correctly — this ADR only
  guarantees the harness underneath that coverage stays switched on.
