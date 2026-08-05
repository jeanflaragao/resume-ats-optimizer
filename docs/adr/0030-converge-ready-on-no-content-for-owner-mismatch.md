# ADR-0030: Converge `DownloadsController#ready` on `204 No Content` for an owner mismatch

## Status
Accepted

## Context

ADR-0029 made `DownloadsController#show` treat a `download_id` owned by a different session as
indistinguishable from one that never existed — a real oracle at the time, since `#create`'s new
redirect put `download_id` in the address bar for the first time, where it can be copied out.

`DownloadsController#ready` had the same class of gap, left alone by ADR-0029 on the grounds that
it's a `fetch()`-only endpoint hit once by `download_status_controller.js`'s own `connect()`, for a
`download_id` that page's own session had just created — not a URL a session hands around. ADR-0029
is exactly what removes that premise: once `download_id` sits in the address bar, `#ready` becomes
the one remaining place in `DownloadsController` where another session's id is distinguishable
(`404`) from a nonexistent one (`204`).

### What the Stimulus controller does with each status (checked before picking a target status)

```js
connect() {
  fetch(this.urlValue, { headers: { Accept: "text/html" } }).then((response) => {
    if (!response.ok) return
    response.text().then((html) => { if (html.trim()) this.element.outerHTML = html })
  })
}
```

It branches on `response.ok` only — true for any 2xx status, false otherwise. `204` (`ok`, body
spec-guaranteed empty) and `404` (`!ok`, exits the guard immediately) already produce the identical
client-visible outcome: no DOM swap. Neither status is inspected specifically. So converging both
server-side outcomes onto one status changes zero client behavior, in either direction, for the one
caller this endpoint actually has.

## Decision

Rescue the owner-mismatch `ActiveRecord::RecordNotFound` locally in `#ready` into `head
:no_content` — the same status the "not yet cached" and "never existed" branches already share
(both return before the ownership check is even reached), not `404`. `204` is picked deliberately
over `404` for a reason specific to this endpoint (unlike `#show`, which picked its own generic
redirect): `#ready` already promises callers "no content yet" via `204` for the in-progress case —
converging on `404` instead would mean *changing* that existing, tested promise, not just closing
the new gap.

Same residual as ADR-0029, restated rather than silently repeated: an owner-mismatch id still costs
one extra `find_owned_resume!` query that a truly-nonexistent id skips — a timing difference in
principle, not a practical one against a 122-bit UUID.

## Alternatives considered

- **Converge on `404` instead**: rejected — would require also 404ing the legitimate
  "not-ready-yet" case (the only way to keep all three outcomes uniform), which changes an existing
  behavior this issue never asked to touch and that `download_status_controller.js`'s own comment
  documents as the expected steady state during normal polling.
- **Distinguish server-side but normalize client-side in JS instead**: rejected — leaves the raw
  HTTP response itself as the oracle for any caller other than this one Stimulus controller (e.g.
  a direct `fetch`/`curl` against the endpoint), which is the actual property being closed.

## Consequences

- `DownloadsController#ready` and `#show` now share the same property: a `download_id` belonging
  to a different session is indistinguishable from one that never existed.
- No client-side (`download_status_controller.js`) change was needed — confirmed by reading it,
  not assumed, before committing to a target status.
- ADR numbering: this is `0030`, not `0029`, because ADR-0029 was still an open, unmerged PR when
  this branch was cut from `master`; by the time it merged the number was already taken. Noted so a
  future reader isn't confused by the gap in the numbers relative to when each issue was filed.
