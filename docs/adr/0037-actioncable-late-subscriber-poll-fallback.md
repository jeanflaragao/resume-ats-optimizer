# ADR-0037: Keep the one-shot poll-on-connect fallback for ActionCable's late-subscriber race

## Status
Accepted

## Context
Issue #18 ("Build PDF download flow," closed by PR #49) built the download status page on a Turbo
Stream broadcast: `Resume::OptimizedPdfJob` finishes and calls
`Turbo::StreamsChannel.broadcast_replace_to`, and `downloads/pending.html.erb`'s
`turbo_stream_from "download_#{download_id}"` subscription is supposed to receive it. During that
same work, manual browser testing turned up a real race: ActionCable does not queue a broadcast
for a subscription that is still connecting, so a broadcast that fires in that window is simply
lost, leaving the page stuck on "Generating your optimized resume PDF..." forever even though the
download succeeded. PR #49's own description records this: *"Also fixed, found the same way: the
job can finish and broadcast before the status page's ActionCable subscription connects... A small
Stimulus controller check[s] once on connect and swap[s] in the result if the job already
finished."*

That fix — `DownloadsController#ready` returning the rendered `downloads/_ready` partial once the
job has finished, or `204` otherwise, with `download_status_controller.js` calling it exactly once
on connect — was small and reactive, built to close a bug found mid-implementation during issue
#18, not the product of a considered design discussion about the right fallback shape. Issue #72
("Revisit the ActionCable late-subscriber race fix as its own ADR") exists specifically to have
that discussion and record its outcome, which is this ADR.

A second, related gap surfaced later, found and fixed inside PR #80 alongside the Windows-1252
font-crash fix it primarily shipped (issue #74) rather than tracked as its own issue: a **failed**
job broadcast and re-raised without writing anything to the cache, so a lost failure broadcast left
`#ready` returning `204` — indistinguishable from "still running" — permanently. That gap is closed
already, outside issue #72's own scope: ADR-0018 decision 4 made the job write
`{ resume_id:, error: }` under the same cache key on every failure path, and made `#ready` render
`downloads/_failed` when it finds one. ADR-0018 says so explicitly: *"This is the minimum that makes
decision 2's message actually reach the user; it deliberately does not change the one-shot-poll
design that #72 exists to revisit."* This ADR is that revisit. It records decision (1) below as
new; decision (2) is recorded only by reference to ADR-0018 decision 4, not re-decided here.

## Decision

**1. Keep the one-shot poll on connect. Do not replace it with continuous polling.**

ActionCable only drops a broadcast during the window where a subscription is still connecting.
Once connected, the channel delivers reliably — there is no ongoing loss mode for it to cover.
Continuous polling would add sustained request load and client-side complexity (timers, backoff,
cleanup on navigation) to guard against a failure mode that stops being possible the moment the
subscription completes. The one-shot check on `connect()` matches the fallback to the actual shape
of the race: it exists only to catch a broadcast that could have already fired *before* the
listener was ready, not to substitute for the listener afterward.

**2. The failure-path fix (cache write on failure, `#ready`'s branch, the `_failed` partial) is
already decided and shipped — recorded by ADR-0018, not this ADR.** See
[ADR-0018](0018-embed-liberation-sans-with-dejavu-fallback.md), decision 4, for the fail-closed
reasoning. It is recorded here only by reference, so this ADR is a complete answer to "what did we
decide about the late-subscriber race" without restating what ADR-0018 already settled.

## Alternatives considered
- **Continuous/interval polling from `download_status_controller.js`** — rejected. The loss window
  closes permanently at connection time; polling after that point would run for the entire
  "Generating..." duration for zero additional benefit, on every page load, for every user.
- **Exponential-backoff reconnect strategy** — rejected for the same reason as continuous polling,
  with added implementation complexity (timer state, cleanup on Turbo navigation) and no coverage
  benefit, since the race it would also catch is already fully covered by the one-shot check.

## Consequences
- The one-shot-poll fallback built during issue #18 is now a recorded decision rather than an
  unexamined artifact of how it was originally built under time pressure. Future changes to the
  download flow's connection sequence should preserve the property this relies on: the fallback
  fires once, on connect, and is a no-op if the broadcast already arrived.
- CLAUDE.md's Project layout entry for `DownloadsController`/`Resume::OptimizedPdfJob` now points
  here instead of carrying this reasoning inline.
- The remaining gap in this area is test coverage, not mechanism: no system-level (real browser)
  test exercises either the late-subscriber race or the failure path end to end. That is issue
  #78's scope, not this one's.
