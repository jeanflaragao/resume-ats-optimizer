# ADR-0027: Disable Turbo's progress bar rather than widen style-src

## Status
Accepted — part of enabling the Content Security Policy in issue #60, PR #110

## Context

Issue #60's policy is `style-src 'self'`, no `'unsafe-inline'`. Running the real system
test against it (not assumed from reading Turbo's source) surfaced a violation from
`turbo.min.js`, root-caused by reading the unminified `turbo-rails` 2.0.23 source
directly: Turbo's built-in navigation progress bar (`ProgressBar`, `app/assets/javascripts/turbo.js`)
has two separate, unrelated style-src problems, not one.

**1. The constructor sets one deterministic inline style, unconditionally.**
`ProgressBar#constructor` calls `this.setValue(0)`, which calls `refresh()`, which sets
`this.progressElement.style.width = "10%"` — every single time `ProgressBar` is
instantiated, which happens as a side effect of `import "@hotwired/turbo-rails"`, before
any application code runs and regardless of whether the bar ever becomes visible. There
is no public Turbo API to prevent this specific call.

**2. Once visible, it trickles via `Math.random()` on every tick.** `show()` — gated by
`progressBarDelay` (default 500ms) — starts a 300ms interval that does
`this.setValue(this.value + Math.random() / 100)`, each tick producing a **different**
`style.width` percentage.

These require different fixes, and only one of them is fixable at all without weakening
the policy:

- The constructor's value is a single fixed string, `width: 10%` — every time,
  byte-identical. CSP nonces cannot cover it (nonces only attach to `<style>`/`<script>`
  elements, never to inline `style=` attribute mutations via the CSSOM), but a CSP3
  **hash** can: `'unsafe-hashes' 'sha256-WAyOw4V+FqDc35lQPyRADLBWbuNK8ahvYEaQIYF1+Ps='`
  in `config/initializers/content_security_policy.rb`, allowlisting that one exact value
  and nothing else.
- The trickle's value is **never** the same twice (`Math.random()`), so no fixed hash,
  or any finite set of hashes, can cover it. This is not fixable within `style-src`
  short of `'unsafe-inline'`.

**This was found empirically, and the first fix attempt was wrong.** The initial attempt
set only `Turbo.config.drive.progressBarDelay` to a large value, reasoning that
preventing `show()` would prevent all of the bar's style mutations. Re-running the
system test after that change reproduced the **identical** violation — because the
constructor's `setValue(0)` call in problem 1 is not gated by `progressBarDelay` at all.
Both problems needed addressing; fixing only the trickle would have left the
constructor's violation in place, and fixing only the constructor's violation (the hash)
without disabling visibility would leave the trickle's un-hashable, ever-changing values
violating the policy on every real slow request — which describes most of this app's own
key interactions (LLM-backed bullet rewriting, PDF generation).

## Decision

**Both fixes ship together, and depend on each other.** `config/initializers/content_security_policy.rb`
allowlists the constructor's one literal value by hash. `app/javascript/application.js`
sets:

```js
Turbo.config.drive.progressBarDelay = 2147483647
```

— the maximum delay `setTimeout` accepts as a 32-bit signed integer (`Infinity` is not
a finite number and browsers clamp/coerce it unpredictably, which would risk firing
near-immediately instead of never). This prevents `show()` from ever running within any
realistic request duration, which prevents `installProgressElement()` (which inserts the
bar into the DOM and sets its opacity) and `startTrickling()` (the random-width interval)
from ever running.

**This line is load-bearing, not incidental.** Deleting it does not just restore a
cosmetic loading bar — it reintroduces the un-hashable trickle violation described
above, on every request across the whole app that takes longer than 500ms, including
under the *enforcing* policy this ADR ships alongside. Under enforcing, that would not
just be a duplicate report-only log entry: each blocked mutation is a style change the
browser genuinely refuses to apply, so the bar would visibly stick or glitch rather than
animate, on top of the console spam. The hash above covers *only* the constructor's
`width: 10%` — it does not and cannot cover the trickle, no matter how the delay is
configured.

**Consequence accepted, and stated plainly: this disables navigation/loading progress
feedback across the entire app, permanently, not just for the flows this PR touched.**
`resumes/show.html.erb`'s "Check match"/"Preview optimized resume" and
`downloads/create.html.erb`'s "Preparing your download"/"Generating..." text cover the
slow requests that exist today. **Any future feature that adds a new slow Turbo-driven
interaction without its own status text will have no loading indicator at all**, and
nothing will surface that fact — the bar is silently absent, not silently broken. Anyone
adding a new slow flow should know this line exists and either add explicit status text
(the pattern already used here) or revisit this ADR if Turbo ever ships a
CSP-nonce-aware or class-toggle-based (rather than direct `style=` mutation) progress
bar in a future version.

## Alternatives considered

- **Add `'unsafe-inline'` to `style-src`** — rejected. This is exactly what issue #60's
  own "do not improvise" section names as unacceptable: it would allow *any* inline
  style anywhere, not just Turbo's, making the directive decorative rather than
  enforced. Also unnecessary: only one of the two problems actually requires it, and
  that one is avoidable by not triggering the code path at all.
- **Monkey-patch or override `Turbo.ProgressBar`** (e.g. replacing `refresh()`/`trickle()`
  to toggle a CSS class instead of setting `style` directly) — rejected as
  materially larger and more fragile than disabling the feature: it means maintaining a
  compatibility shim against a third-party library's internal, undocumented class across
  future `turbo-rails` upgrades, for a purely cosmetic loading indicator this app can
  live without.
- **Leave `progressBarDelay` at its default and accept the trickle violations as a known
  gap** — rejected. Every one of this app's own slow interactions would violate the
  policy on essentially every real use, which is indistinguishable from not having
  `style-src` enforcement at all for those requests, and (per the "load-bearing" point
  above) would look visibly broken under enforcing, not just noisy in report-only.

## Consequences

- No Turbo progress bar anywhere in the app, on any page, indefinitely. This is a
  deliberate, permanent UX trade-off made as part of security work, not a temporary
  stopgap — there is no tracking issue to "restore" it, because restoring it as-is is
  not possible without widening `style-src`.
- The hash in `config/initializers/content_security_policy.rb` is coupled to the exact
  `turbo-rails` version's `ProgressBar.defaultCSS`/`refresh()` implementation. A
  `turbo-rails` upgrade that changes the constructor's initial value changes or removes
  the string the hash was computed over — the violation reappears (report-only, or the
  system test's `assert_no_csp_violations!`), which is the intended failure mode: loud,
  not silent.
- Any new feature adding a slow Turbo-driven interaction needs its own explicit loading
  feedback; none will be provided automatically.
