# ADR-0010: Accept `data: { turbo: false }` as a stopgap for POST-rendering controllers

## Status
Superseded by [ADR-0014](0014-convert-post-controllers-to-turbo-stream-responses.md) — issue #47
converted all three affected actions to real `turbo_stream` responses and removed
`data: { turbo: false }` from all three forms; see ADR-0014 for what replaced this stopgap and
what it cost. (Previously amended, not superseded, by
[ADR-0013](0013-enable-forgery-protection-in-system-tests.md) — issue #57 closed the related
CSRF-forgery blind spot this ADR's Context/Consequences describe for system tests specifically;
see ADR-0013 for what was covered before #47 landed.)

## Context
ADR-0001 committed this app to a Turbo-driven monolith, which implies Turbo Drive intercepting
form submissions. Issues #16, #17, and #18 each added a controller action
(`JobDescriptionsController#create`, `PreviewsController#create`, `DownloadsController#create`)
that responds to a POST by directly `render`-ing an HTML template — not a redirect, not a
`turbo_stream` response. This went unnoticed through #16 and #17 because neither had a system
test exercising a real browser; integration tests run in-process and never see Turbo Drive
reject anything client-side. Issue #18 added this repo's first system test
(`test/system/resume_downloads_test.rb`, Capybara + Selenium), and it immediately failed with
`Error: Form responses must redirect to another location` — not only in #18's own new code, but
in the already-merged #16/#17 controllers too. Turbo Drive enforces Post/Redirect/Get for any
form submission it intercepts that isn't a `turbo_stream` response, specifically to avoid the
"confirm form resubmission" problem on page refresh; a plain `200 OK` HTML render doesn't
satisfy that, so from the user's perspective the click silently does nothing (the request
succeeds server-side, but the page never updates).

## Decision
Add `data: { turbo: false }` to the affected forms (`resumes/show.html.erb`'s job-description
form and the "Preview optimized resume" form, `previews/show.html.erb`'s download form), forcing
a real full-page browser submit/reload instead of a Turbo-intercepted fetch, as an interim fix.
This is explicitly documented as a stopgap, not the intended end state — issue #47 (open) tracks
converting all three actions to real `turbo_stream` responses instead, which is what ADR-0001's
own architecture actually calls for.

## Alternatives considered
- **Immediately convert all three actions to `turbo_stream` responses** (the "proper" fix):
  rejected as the immediate fix specifically because it's a larger, riskier change to make while
  already mid-issue-#18 with a newly-failing system test blocking progress; `data: turbo: false`
  restores correct behavior with a one-line change per form, buying time to do the `turbo_stream`
  conversion properly and separately (tracked as issue #47) rather than rushed.
- **Redirect instead of render** (satisfies Turbo Drive's Post/Redirect/Get expectation without
  `turbo_stream`): would require a second GET request to reconstruct and re-render page state
  (comparison results, match score, preview data) that the current `render` has directly
  available post-POST, likely via session/flash smuggling of non-trivial data. Not pursued as
  the interim fix; `turbo_stream` (deferred to #47) is the more correct long-term direction
  anyway, so this alternative wasn't worth building as a separate intermediate step.

## Consequences
- Three forms currently perform full-page reloads instead of the partial, in-place updates
  ADR-0001's Turbo Streams architecture is meant to provide — a real, acknowledged UX
  regression relative to the intended design, not just a technical loose end.
- This bug was invisible to every test in the repo prior to issue #18's system test — a
  concrete argument for why system tests earn their cost even in a project that otherwise
  favors faster in-process integration tests.
- Issue #47 remains open; this ADR's status will effectively be superseded once that work lands
  and the `data: { turbo: false }` attributes are removed.
