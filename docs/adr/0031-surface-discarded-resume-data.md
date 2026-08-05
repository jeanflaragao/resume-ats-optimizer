# ADR-0031: Persist discarded resume data as pending items, and never prefill a possibly-fabricated one

## Status
Accepted

## Context

`Resume::Extractors::Llm` and `Resume::Import#parse_date` have both discarded user data
silently since they were written: fidelity-check drops (#37) went to `Rails.logger.warn` only,
and an unparseable date (#112) became a bare `nil`. Neither left the resume owner any way to know
what was missing or to supply it. #37 was the open, unmilestoned "design and build a
change/fidelity report" issue waiting on exactly this product decision; #112 turned out to be the
same underlying problem — silent data loss, visible only in the log — surfacing through a
different code path. Consolidated and worked as one feature; #112 closed as a duplicate of #37.

**Measured before designing the UI**, per this repo's own working agreement not to build for a
volume nobody observed: one real extraction against the user's actual LinkedIn export produced
3 experiences, 2 educations, 2 skills, and **one** pending item total (a dropped skill). That
sample — plus the reasoning below on why unparsed dates specifically will stay rare even after
this ships — is why the result is a quiet inline list on `resumes/show.html.erb`, not a dedicated
panel or page.

Scope was bounded explicitly going in: this is a narrow form for fields the pipeline couldn't
populate, not general resume editing or CRUD on `Experience`/`Education`.

## Decision

### Three cases, three treatments — this distinction is the whole design

1. **Unparsed date** (`Resume::Import#parse_date`): the value passed the LLM's own
   truthfulness check (`Extractors::Llm#verified_year`) but isn't `Date.parse`-able. This is the
   user's own true data — we understood *that* it was a date, just not *which* one. Shown back
   verbatim: "we couldn't read 'Summer 2020' as a date."
2. **Possibly-fabricated field** (every `verified_*` drop in `Extractors::Llm`): failed
   LLM-output verification against the source document. **The discarded value is never persisted
   at all** — not encrypted-and-hidden, not persisted-but-unrendered, genuinely never written down
   anywhere outside the existing redacted log line. Only a category (`field`) and a
   human-readable reason survive. This is deliberate and asymmetric with case 1: prefilling a
   fabricated value would let the user unknowingly confirm a false fact about their own life
   (wrong employer, wrong school, a skill they don't have) by doing nothing more than clicking
   accept. A blank field the user has to actively fill is a strictly safer failure mode than a
   plausible-looking wrong one. Field left blank for the user to type.
3. **Bullet fell back to original wording** (`BulletRewriter`): nothing was lost, so nothing
   needs a fill-in — informational only. **Cut from this PR**, filed as
   [#117](https://github.com/jeanflaragao/resume-ats-optimizer/issues/117): it shares no
   persistence mechanism with the other two (in-memory, re-derived every
   `Resume::CachedOptimization` run, never touches the database), so it costs real, separable
   work — a `BulletRewriter` return-shape change, a new `Resume::Optimization::Experience` field,
   a `Resume::CachedOptimization::KEY_VERSION` bump, a preview-view change — for comparatively
   little (a badge saying nothing was lost). Cutting it costs no rework on the other two cases.

### Why case 1 will stay rare even after this ships

`Resume::ExtractionSchema` instructs the LLM to normalize dates to `YYYY-MM-DD`/`YYYY-MM`, and
`verified_year` already gates every date *before* `parse_date` ever sees it: a string that
doesn't start with 4 real digits is caught there first, as a **case 2** drop (possibly
fabricated), not a case 1 parse failure. `parse_date`'s own rescue is reachable only by (a) a
verified-but-malformed date (e.g. an invalid day/month that still starts with 4 real digits, so
`verified_year` lets it through) or (b) the `"regex"` strategy, which does no fidelity
verification at all and is not exposed to end users today (`ResumesController` hardcodes
`strategy: "llm"`). Recorded so nobody "fixes" the rarity later expecting more volume than the
pipeline actually produces.

### Data model: `jsonb pending_items` columns, not a table

`pending_items:jsonb, null: false, default: []` added to `resumes`, `experiences`, and
`educations` — no new table, no new AR model. Each element:

```json
{ "kind": "unparsed_date" | "dropped_field", "field": "starts_on", "reason": "...", "raw_value": "Summer 2020" | null }
```

`raw_value` is populated *only* for `kind: "unparsed_date"`; every `dropped_field` item has
`raw_value: null` **by construction** — `Resume::Extractors::Llm#pending_item` takes no
`raw_value` argument at all, so there is no call site that could pass one. This is proven, not
just documented: a test temporarily made one drop site pass the raw value through, confirmed it
fails (`assert_nil pending item for name must never carry the dropped value. Expected "John
Smith" to be nil.`), then the change was reverted. Chosen over a table because the measured volume
(0–2 items per resume) doesn't justify one, and because storing pending items as columns on the
rows they describe means `Resume.purge_stale!`'s existing `dependent: :destroy` cascade
(ADR-0026) deletes them for free — same 7-day/24-hour retention window as the rest of the resume,
no new purge job, no new `config/recurring.yml` entry.

Multiple drops of the same array-valued field (skills, bullets) are **aggregated into one
pending item**, not one per drop — `Resume::Extractors::Llm#verified_skills`/`#verified_bullets`.
`PendingItemsController` identifies a pending item by `(scope, field, position)`, which is only
unique if a field can have at most one pending item; without aggregation, two dropped skills
would produce two identical hashes, and `Array#-` would remove both when the user meant to
resolve one.

### Privacy: checked against ADR-0015, ADR-0022, ADR-0026 — no contradiction

- **ADR-0015** governs log redaction, not persistence, and its own stated fix was "redaction, not
  silence." Persisting case-2 items as category + reason, never the value, is that same
  redaction moved from log-only to log-and-persisted-metadata — no new sensitive value class
  enters storage.
- **Case 1's `raw_value` is new persisted data** (`parse_date` logs nothing today), but it's the
  same sensitivity class as the `starts_on`/`ends_on` columns sitting next to it — neither
  `Experience` nor `Education` encrypts any column. **Not encrypted** — ADR-0022 encrypted
  `PdfRequest.text` specifically because identical ciphertext would let a reader correlate two
  users applying to the same job; a resume's own messy date string carries no comparable
  correlation risk.
- **ADR-0026** retention is inherited for free, as above — no new constant to get wrong.

### The fill-in form deliberately bypasses FidelityCheck — and is correct to

`PendingItemsController#create` writes the submitted value straight to the record — `record[field]
= value`, or an array append for `skill`/`bullet` — with **no `FidelityCheck` call and no LLM
call**. This is not an oversight. `FidelityCheck` exists to stop the LLM from putting invented
content in front of the user as verified fact; it has no jurisdiction here, because the value
isn't LLM output being laundered past verification — it's the resume owner directly asserting a
fact about their own life (their own date, their own skill, their own bullet). Running it back
through `FidelityCheck` would mean checking the user's word against the user's word. Consistent
with "no LLM calls inside deterministic services" (CLAUDE.md's Architecture Conventions):
`PendingItemsController` stays fully deterministic.

### Scope conflict, resolved: a whole dropped entry is inform-only, not re-addable

`verified_experience`/`verified_education` also drop **entire** entries (company/title/school
itself unverifiable or blank) — filtered out before `Import` ever sees them, so there's no
`Experience`/`Education` row and no `position` to attach a fix to. The task's own scope line rules
out "full CRUD on Experience and Education." Recreating a dropped whole entry means typing
company *and* title *and* dates *and* bullets — multi-field entry creation, exactly what that line
excludes. **Resolution: a dropped whole entry is inform-only** — "an experience entry couldn't be
verified" — with no form. `PendingItemsController::FILLABLE_FIELDS` is the actual enforcement
(not just the view): it omits `"experience"`/`"education"`, so even a hand-crafted POST for one
404s. Every other case-2 drop (a field *within* a still-existing entry, or a resume-level scalar)
stays in scope, since each is a genuine single field on a row that already exists.

## Alternatives considered

- **A `resume_pending_items` table**: rejected — proportionate to a measured volume of 0–2 items,
  a `jsonb` column matches this codebase's existing pattern (`Resume.skills`, `Experience.bullets`)
  and gets free retention via the existing purge cascade that a table would need its own
  `purge_stale!` for.
- **Encrypting `raw_value`**: rejected — no correlation risk comparable to ADR-0022's job
  description text, and no other resume field is encrypted either.
- **Allowing a full re-add form for a dropped whole entry**: rejected as out of scope per the
  task's own line against full CRUD; flagged rather than silently built or silently dropped.
- **Running fill-in values through `FidelityCheck`**: rejected — there is nothing to verify a
  first-party assertion against; see above.

## Consequences

- `resumes/show.html.erb` gains a quiet, inline pending-items list (not a panel) with one small
  form per fillable item, backed by `ResumesHelper#pending_item_rows`.
- `PendingItemsController#create` is the single write path; ownership is enforced by the existing
  `find_owned_resume!` (its `RecordNotFound` deliberately falls through to Rails' default 404,
  same as every other owner-scoped controller — ADR-0029), and a fill uses `update!`/`save!`, not
  `update_column`, so it correctly bumps `updated_at` and invalidates
  `Resume::CachedOptimization`'s cache (a stale cached optimization must not survive the user
  fixing their own data).
- Case 3 (bullet-fallback notice) remains open as
  [#117](https://github.com/jeanflaragao/resume-ats-optimizer/issues/117); this PR is `Part of
  #37`, not `Closes #37`, until that lands.
- `Extractors::PdfRegex`/`JsonMapper` (the `"regex"` strategy) never populate `pending_items` —
  `Resume::Import#persist` defaults to `[]` — so they're unaffected; only case 1 is reachable
  through that strategy at all, and only if it's ever exposed to end users.
