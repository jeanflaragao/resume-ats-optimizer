# ADR-0002: Use Rails 8's Solid Queue/Cache/Cable instead of Redis

## Status
Accepted (Amended by [ADR-0012](0012-wire-solid-cache-as-production-cache-store.md))

## Context
The product needs background job processing (LLM calls and PDF rendering are slow and
cost-bearing — issue #1 flagged both as unsuitable to run inline in a multi-user hosted request
cycle), a cache, and a pub/sub mechanism to push results back to the browser (Turbo Streams,
eventually needed by issue #18's download flow). The traditional Rails answer to all three is
Redis plus Sidekiq/ActionCable's Redis adapter. The app is deployed with Kamal to a single VPS
by a solo maintainer, where every additional service is something that has to be provisioned,
monitored, and kept running without a dedicated ops team.

## Decision
Use Rails 8's "Solid trio" — Solid Queue, Solid Cache, Solid Cable — all backed by the existing
Postgres instance instead of Redis. Background jobs, caching, and ActionCable pub/sub all run
off the one database the app already needs for its own data.

## Alternatives considered
- **Redis + Sidekiq + Redis-backed ActionCable**: the conventional, more battle-tested choice
  for job throughput at scale, but requires provisioning and operating a second stateful
  service under Kamal. Rejected: this project has no throughput requirement that Postgres-backed
  queuing can't meet, and "one fewer service to run" was an explicit goal from issue #1's
  proposal for a solo-maintainer VPS deploy.
- **Inline/synchronous execution (no background jobs at all)**: simplest possible option, but
  directly contradicts the requirement that slow LLM/PDF work not block the request cycle, and
  removes the natural place (a job) to eventually enforce per-user rate limiting (issue #22).
  Rejected.

## Consequences
- One Postgres instance is the only stateful dependency in production — `config/deploy.yml`
  (once issue #48 creates it) only needs to provision a database, not a database plus Redis.
- `config/cable.yml` had an unused, contradictory `redis` adapter in production left over from
  Rails' default scaffold; issue #18 (the first real ActionCable broadcast) is what actually
  pointed it at `solid_cable`, closing that latent inconsistency.
- Development and test intentionally do *not* also run Solid Queue locally — they stay on
  Rails' default in-process `:async` adapter (decided in issue #18), since Turbo Stream
  broadcast behavior is identical from the browser's perspective regardless of which
  ActiveJob adapter ran the job, and Solid Queue's actual benefits (durability, admin
  visibility across restarts) don't matter for a local dev/test run.
- If job volume or latency ever genuinely outgrows a Postgres-backed queue, this decision would
  need revisiting; no such evidence exists at this project's current scale.
