# ADR-0036: Stripe Checkout for credit packs and the unlimited window

## Status
Accepted.

## Context

Issue #122 (ADR-0035) shipped the credit balance/unlimited-window schema — `users.credits`,
`users.unlimited_until`, `Credit.available?`/`Credit.consume!` — but nothing to actually put money
behind it. This is the fourth and final issue in the sequence: three one-off Stripe Checkout
Sessions (5 credits, 15 credits, 30-day unlimited) and a webhook that grants on completion. No
auto-renewal means no subscriptions — no dunning, no cancellation webhooks; scope is a Checkout
session, a webhook handler, and `stripe_customer_id` on `User`.

Two decisions were explicitly left open by the issue's own prompt for this ADR to make and justify:
what a second unlimited-window purchase means while the first is still active, and which Stripe
event type the webhook should key off. Both are decided below, not deferred. A third question —
how much to invest in the UX of the gap between paying and the webhook landing — was raised and
resolved in favor of fully reusing this codebase's existing Download pattern (Turbo Stream broadcast
plus a fallback poll), rather than inventing a lighter alternative; the reasoning is recorded under
Decision below.

## Decision

### Where products and prices live

Stripe Price ids are deploy config — different per Stripe account and per test/live mode, exactly
like `ANTHROPIC_API_KEY`. The grant each price represents (5 credits, 15 credits, 30 days) is
business logic and belongs in code, reviewed like any other constant. `Payments::Catalog` is a
frozen list of `Data.define`d entries, each pairing an app-level key with the `ENV` var name holding
its Price id:

```ruby
Entry = Data.define(:key, :env_var, :credits, :unlimited_days, :amount_cents, :label)
ENTRIES = [
  Entry.new(key: :five_credits,      env_var: "STRIPE_PRICE_ID_5_CREDITS",         credits: 5,  unlimited_days: nil, amount_cents: 1490, label: "5 credits"),
  Entry.new(key: :fifteen_credits,   env_var: "STRIPE_PRICE_ID_15_CREDITS",        credits: 15, unlimited_days: nil, amount_cents: 2490, label: "15 credits"),
  Entry.new(key: :unlimited_30_days, env_var: "STRIPE_PRICE_ID_UNLIMITED_30_DAYS", credits: nil, unlimited_days: 30, amount_cents: 3990, label: "30-day unlimited"),
]
```

`.price_id_for(key)` (forward lookup, session creation) and `.for_price_id(id)` (reverse lookup,
webhook) both read `ENV` at call time, never memoized at class-load — the same reason
`Usage::Quota.limit_for` doesn't memoize at boot. Named `Catalog`, not `Product` or `Price`: the
`stripe` gem already defines `Stripe::Product`/`Stripe::Price` as real API resources, and a
same-named app-level class next to them would be confusing to read even though the namespaces don't
collide.

### Never trust the client — the grant follows the event's own line items, not anything decided at session-creation time

`Payments::CheckoutsController#create` sets `client_reference_id: Current.user.id.to_s` from the
*authenticated* session — unforgeable, since the browser never supplies it — and creates the
Checkout Session for exactly the `price:` the user selected. But the grant itself is computed in the
webhook from `Stripe::Checkout::Session.list_line_items(session.id).data.first.price.id` — the price
Stripe itself reports as paid, fetched fresh via a follow-up API call (not expanded on the event
payload by default) — never from `session.metadata` or anything else this app might have set
earlier. This is deliberately stricter than trusting our own prior intent: even if session creation
and actual payment could somehow diverge, the grant still follows only what Stripe confirms was
purchased. A tampered client request claiming "start checkout for the 15-credit pack" that actually
completes payment for the 5-credit price still only grants 5 credits.

### Idempotency — a database-level unique constraint is the actual guard

Stripe retries webhook delivery on anything but a 2xx response, including after a handler already
succeeded but failed to return in time — a double-processed event means free credits, real money. A
new `payment_grants` table is unique on `stripe_event_id` (and separately on
`stripe_checkout_session_id`, used by the pending-payment page's fallback lookup). The grant and the
idempotency record are written in one transaction:

```ruby
ActiveRecord::Base.transaction do
  Payments::Grant.create!(stripe_event_id: event.id, stripe_checkout_session_id: session.id,
                           user: user, stripe_price_id: price_id,
                           credits: entry.credits, unlimited_days: entry.unlimited_days)
  Credit.grant_credits!(user, entry.credits) if entry.credits
  Credit.grant_unlimited_days!(user, entry.unlimited_days) if entry.unlimited_days
  # backfill stripe_customer_id, only if currently blank
end
```

A replayed event's `Grant.create!` raises `ActiveRecord::RecordNotUnique` — the **unique index**, not
a Rails `validates uniqueness` (a SELECT-then-INSERT race the same shape `Credit.consume!` already
had to avoid in #122) — which aborts the whole Postgres transaction: nothing partially applies.
`Payments::GrantFromEvent` rescues that specific exception, logs it as an expected replay, and
returns; the controller answers `200` either way, which is what stops Stripe from retrying further.

`payment_grants.credits`/`.unlimited_days` record what *this* grant added, not a running total —
consistent with each other, and this avoids needing an audit-time read of the user's current balance
that could itself race a concurrent grant. The authoritative resulting balance is always
`users.credits`/`users.unlimited_until`, computed atomically by the two `Credit` mutators below,
never recomputed or duplicated in the audit row.

**Non-vacuity, per the working agreement**: this test was first run with the two unique indexes
dropped and the `ActiveRecord::RecordNotUnique` rescue removed, and failed by granting the same
5-credit event twice — a user starting at 2 credits ended at **12**, not 7, after the same event was
delivered twice. Output recorded in the PR body. Restoring both is what makes it pass.

### Two new atomic `Credit` mutators, same discipline as `consume!`

- `Credit.grant_credits!(user, amount)` — `credits = credits + ?` via `update_all`. Purely additive,
  so there's no prior value to race against in the first place.
- `Credit.grant_unlimited_days!(user, days)` — one atomic SQL expression:
  `unlimited_until = GREATEST(COALESCE(unlimited_until, ?), ?) + (? * INTERVAL '1 day')`, binding
  `Time.current` twice and `days`.

Both live on the existing `Credit` class from #122, not a new `Payments::` class — it already owns
every other mutation of `credits`/`unlimited_until`, and keeping all of it in one file makes "what
can change a user's balance" a one-file audit regardless of which issue introduced a given method.

**Extending the unlimited window: stack on top of the later of "now" or the current expiry, never
just "now."** Decided explicitly, per the issue's own request. A user who buys a second unlimited
window while the first still has, say, 10 days left must not have those 10 days silently absorbed
into a fresh 30 — `GREATEST(COALESCE(unlimited_until, now), now)` picks whichever is later (the
still-active expiry, or "now" if the window already lapsed), and the new 30 days is added on top of
that. Total paid-for access is always additive, regardless of *when* within an active window the
second purchase happens; a user who buys twice in one month and lost the overlap would notice, and
this makes sure they don't. A single SQL expression, not a Ruby read-then-compute-then-write, for the
same reason `consume!` is raw SQL: two genuinely concurrent grants (two real purchases landing at
once) must not race each other's read of the prior value. Proven with a concurrency test mirroring
`credit_concurrency_test.rb`'s #122 lesson directly: each concurrent grant call reloads its own
`User` instance rather than sharing one Ruby object, because a shared object's `assign_attributes`
would mutate in-memory state synchronously before the network round-trip the race actually depends
on, silently masking the exact bug the test exists to catch (confirmed the hard way — see
Consequences).

### Reserve-then-confirm was considered and rejected

By the time `Payments::GrantFromEvent` runs, the payment has already succeeded — that's what a
`checkout.session.completed` event with `payment_status: "paid"` means. There is nothing left to
reserve: a reservation would need a release path for the case where the "confirming" step never
completes (a crashed process, a bug), and that path has no correct answer that isn't "eventually
become the same unconditional charge-on-success this ADR already does." The grant is instead simply
idempotent (above) — a replayed or retried delivery is a safe no-op, not a state machine to manage.

### Webhook event: `checkout.session.completed`, not `payment_intent.succeeded`

Current Stripe guidance for Checkout-driven one-off payments is to key off the Checkout Session's
own completion event — it reliably carries `client_reference_id` and is scoped to exactly the
sessions this app creates, unlike `payment_intent.succeeded`, which fires for any PaymentIntent
regardless of origin (including ones this app never created). `Payments::GrantFromEvent` additionally
checks `session.payment_status == "paid"` before granting anything. For v1's card-only flow this is
always true (card payments confirm synchronously, so a `completed` session is always a paid one) —
the check exists for the day Pix is added: Pix confirms asynchronously, and a Checkout Session can
reach `completed` with `payment_status: "unpaid"` for it, needing `checkout.session.async_payment_succeeded`
instead/as well. An unrecognized `event.type`, or a price id absent from `Payments::Catalog`, no-ops
with a `200` and a class-and-event-id-only log line — never raises, so a Stripe Dashboard
misconfiguration ("listen to all events" instead of just the one registered) can't turn into retry
storms or 500s.

### Signature verification is the webhook's only authentication

`Payments::WebhooksController` does not inherit `ApplicationController` — it has no browser (would
fail `allow_browser versions: :modern`), no session (Stripe carries no cookie, so
`Authentication`'s `require_authentication` has nothing to resume), and no use for
`ApplicationController`'s flash-redirect-shaped `rescue_from` handlers. It inherits
`ActionController::Base` directly, with `skip_before_action :verify_authenticity_token` (CSRF exists
to stop a browser from replaying an authenticated session's cookie; a request with no session to
forge has nothing for it to protect) and answers bare HTTP status codes only.
`Stripe::Webhook.construct_event(request.body.read, request.headers["Stripe-Signature"],
ENV.fetch("STRIPE_WEBHOOK_SECRET"))` raises `Stripe::SignatureVerificationError` for anything
unsigned or wrongly signed, caught and answered `400` before `Payments::GrantFromEvent` is ever
reached. `request.body.read`, not `params` — signature verification needs the exact raw bytes Stripe
sent; anything that round-trips through Rails' JSON parser first would break the HMAC. Proven with a
real (not just unit-tested) request in `test/controllers/payments/webhooks_controller_test.rb`: a
genuinely signed request grants credits; an unsigned one, a garbage-signed one, and one signed with
the wrong secret are all refused with `400` and grant nothing.

### Pending-payment UX: full reuse of the Download pattern

Between Checkout redirecting back and the webhook actually landing (typically under a second for a
card payment, but not guaranteed), a balance that still reads its pre-purchase value is the worst
moment in the flow to look broken. Rather than build something lighter, `Payments::CheckoutsController#success`
reuses the exact mechanism `Resume::OptimizedPdfJob`/`DownloadsController` already use for a
different async result (issue #72/ADR-0018): the success page subscribes to a Turbo Stream channel
keyed by the Checkout Session id; `Payments::GrantFromEvent` broadcasts a replace to that channel
(`Turbo::StreamsChannel.broadcast_replace_to`, same call shape) once its transaction commits, so a
replayed event's rolled-back transaction never re-broadcasts; and `Payments::CheckoutsController#ready`
mirrors `DownloadsController#ready`'s one-shot fallback check for the case where the broadcast fires
before the page's subscription connects. This was a deliberate choice to copy proven, already-tested
machinery rather than design something new for a problem this codebase has already solved once.

Ownership of the success page itself is checked with the same rigor `find_owned_resume!` applies
elsewhere: a Checkout Session id reaches the success page as a real, copyable query param
(`?session_id=cs_...`), the same "URL that could leak or be shared" property `download_id` has
post-ADR-0029, so a mismatch (checked against Stripe's own `client_reference_id`, via a live
`Stripe::Checkout::Session.retrieve`) and a genuinely nonexistent session id get the identical
redirect and message — matching ADR-0029's indistinguishability requirement rather than letting the
response itself become an oracle.

### `stripe_customer_id`

Backfilled only on a user's first purchase, inside the same grant transaction, only if currently
blank. `Payments::CreateCheckoutSession` forces `customer_creation: "always"` on a session created
without an existing customer id (payment-mode Checkout Sessions don't create a Customer object by
default otherwise), guaranteeing `session.customer` is populated for the webhook to read. Every
later purchase reuses the existing id (`customer:` instead of `customer_email:`), so Stripe doesn't
mint a fresh Customer object per purchase.

## Explicitly out of scope for v1

**Pix.** As of 2026-08-06, Stripe lists Pix as invite-only for Brazil-domiciled businesses
([stripe.com/payment-method/pix](https://stripe.com/payment-method/pix)) and requires 60+ days of
processing history in good standing before eligibility; a new account cannot count on having access
at launch. A non-Brazil-domiciled Stripe account *can* accept Pix from Brazilian customers without
the invite gate, but settles in that account's own currency rather than BRL and is subject to
Brazil's IOF cross-border tax (currently 3.5%, collected via Stripe's Brazil payment partner Ebanx
unless absorbed by the merchant) — a materially different cost/settlement shape than the
Brazil-domiciled path this ADR assumes, not something to design around speculatively. Published
Brazil-domiciled fee comparison: Pix 1.19% per transaction vs. domestic card 3.99% + R$0.39 (+2% for
an internationally issued card) — on a R$14.90 pack, roughly R$0.18 vs. R$0.98, a real cost gap
worth revisiting once invite access exists, not a reason to block v1 on it now.

No Pix-specific code, UI copy, or configuration exists anywhere in this implementation. Adding it
later is a `payment_method_types` entry on the Checkout Session (`["card"]` → `["card", "pix"]`)
once access is granted — the webhook handler, the credit-grant logic, the idempotency mechanism, and
the data model (`stripe_customer_id`, `payment_grants`) are identical either way, except that Pix's
asynchronous confirmation means also handling `checkout.session.async_payment_succeeded`/
`async_payment_failed`, per the payment-status check already noted above.

Also out of scope, none required by the issue: a `Usage::Quota` action type for checkout-session
creation (Stripe rate-limits its own API; nothing here is LLM-cost-bearing), refund/dispute
handling, and an email receipt (no mailer exists anywhere in this app — the same gap ADR-0034 already
noted and declined to build for a retention-deletion warning).

## Consequences

- `payment_grants` (new table) and `users.stripe_customer_id` (new column) are the same shape of
  permanent liability ADR-0034 already established for `credits`/`unlimited_until`: they live on
  `users` or FK to it, never `resumes`, so `Resume.purge_stale!`'s resumes-only `where` clause
  structurally cannot reach either. No new purge-safety guard was written — the existing
  `test/models/resume_test.rb` purge-safety test was extended with two more assertions, per the
  pattern ADR-0034 itself established for this exact test, rather than a new one added.
- `Credit.grant_unlimited_days!`'s concurrency proof needed a second attempt: the first version of
  `test/services/credit_concurrency_test.rb`'s new test shared one `User` Ruby object across
  concurrent grant calls and passed even with the (never-shipped) naive version, because a shared
  object's `assign_attributes` mutates in-memory state synchronously ahead of the network
  round-trip the actual race depends on. Each concurrent call reloading its own `User` instance —
  mirroring how two separate web requests each load their own copy of `Current.user` — is what
  made the test expose anything at all.
- No `STRIPE_PUBLISHABLE_KEY` anywhere in this app. Checkout is a server-side-created, hosted-page
  redirect; nothing client-side ever touches Stripe.js or Stripe Elements, so there's no publishable
  key to configure and no CSP change needed (`connect_src`/`script_src` stay `:self`; `form-action`
  is unset already and redirects aren't governed by CSP navigation directives regardless of that).
- All five `STRIPE_*` env vars are required on both the web and worker Railway services, even
  though nothing Stripe-related is ever enqueued as a background job (checkout creation and webhook
  processing are both synchronous controller actions) — `Payments::ConfigGuard.validate_configuration!`
  runs in every process's boot sequence, worker included, the same reason Google OAuth's pair is
  required on both services already.
