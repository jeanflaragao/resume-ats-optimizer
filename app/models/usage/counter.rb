# How many times one subject has performed one quotaed action inside one period.
#
# Issue #22. This is the storage half of the per-subject rate limit; the limits
# themselves, and the decision to refuse, live in Usage::Quota. It is a separate
# mechanism from LlmCallGuard's global daily cap and deliberately does not
# replace it -- see ADR-0023 and issue #45.
#
# Two independent callers as of ADR-0039, not one: Usage::Quota's four
# per-action action types, and LlmCallGuard's own SUBJECT_ACTION_TYPE
# ("llm_provider_call"), which LlmCallGuard writes and reads directly --
# bypassing Usage::Quota entirely, so a row here does not imply it belongs to
# Usage::Quota's action-type set. Sharing this storage primitive does not
# merge the two mechanisms: they keep separate error classes and messages.
#
# The subject is the signed-in user's id, as a string (issue #121, ADR-0033) --
# see subject_token below. subject_token stays a plain string column rather
# than gaining a dedicated users FK: nothing here joins against it or needs
# referential integrity, and Usage::Counter.purge_stale! already deletes
# independent of any other table's lifecycle.
class Usage::Counter < ApplicationRecord
  # Usage is a plain namespace module, not an ActiveRecord model, so Rails'
  # nested-class table prefixing (which is what gives Resume::PdfRequest its
  # resume_pdf_requests) does not apply here and the inferred name would be
  # "counters". Named explicitly rather than by adding a Usage.table_name_prefix
  # shim, so the mapping is visible where the model is.
  self.table_name = "usage_counters"

  # The only period this app writes today. Usage::Quota owns the decision of
  # which periods exist; this constant exists so consume! has a default that
  # does not silently disagree with it.
  DAY = "day".freeze

  # How long a counter row is kept after its period has passed. Must exceed the
  # longest period in use -- otherwise the purge deletes counters that are still
  # being enforced against -- with margin for a purge that does not run for a
  # while (config/recurring.yml runs it daily, and nothing runs it at all until
  # issue #48 gives Solid Queue somewhere to live in production).
  #
  # Seven days against a one-day period is six days of margin: the purge would
  # have to miss six consecutive runs before it could delete a live counter. It
  # also leaves a week of history to read when sizing the production limits,
  # which is the other thing these rows are good for.
  #
  # Raise this before adding a monthly period (ADR-0023): 7 days is shorter than
  # the period a monthly quota would enforce over, so leaving it would silently
  # reset every subject's monthly count a week into the month.
  RETAIN_FOR = 7.days

  # Increments this subject's counter for this action and period, and returns
  # the new count.
  #
  # One statement, and that is the whole point. Read-then-write -- find_or_
  # create_by followed by increment! -- loses updates whenever two requests for
  # the same subject overlap, which is exactly the case a rate limit exists to
  # catch: a double-submitted form, or a Puma thread and a Solid Queue worker
  # running for the same session at once. Postgres' INSERT ... ON CONFLICT DO
  # UPDATE serialises the two against the unique index instead, so N concurrent
  # callers always leave the count at N.
  #
  # RETURNING gives back the post-increment value for both the inserted and the
  # updated row, so the caller learns its own position in the period without a
  # second read that could observe someone else's increment.
  #
  # Bypasses validations and callbacks, as upsert_all always does. There are
  # none to bypass: every column this writes is either supplied here or has a
  # NOT NULL database default, and the uniqueness that matters is enforced by
  # the index rather than by a model validation that could not be atomic anyway.
  def self.consume!(subject_token:, action_type:, period: DAY, period_start: Date.current)
    now = Time.current

    upsert_all(
      [ {
        subject_token: subject_token,
        action_type: action_type.to_s,
        period: period,
        period_start: period_start,
        count: 1,
        created_at: now,
        updated_at: now
      } ],
      unique_by: :index_usage_counters_on_subject_action_period,
      on_duplicate: Arel.sql("count = usage_counters.count + 1, updated_at = EXCLUDED.updated_at"),
      returning: %w[count]
    ).first["count"]
  end

  # Read-only counterpart to consume! -- used by LlmCallGuard's pre-flight,
  # which (like the global cap's own Rails.cache.read) must not itself
  # increment. pick(:count) rather than find_by + #count to stay a single
  # query with no risk of loading/instantiating a row just to read one column.
  def self.count_for(subject_token:, action_type:, period: DAY, period_start: Date.current)
    where(subject_token: subject_token, action_type: action_type.to_s, period: period, period_start: period_start)
      .pick(:count) || 0
  end

  # Called from config/recurring.yml. delete_all rather than Resume::PdfRequest.
  # purge_stale!'s destroy_all: there is no dependent behaviour to run, nothing
  # else references these rows, and unlike that table the row count here grows
  # with traffic rather than staying near zero -- one row per subject per action
  # per day.
  def self.purge_stale!(now: Date.current)
    where(period_start: ...(now - RETAIN_FOR)).delete_all
  end
end
