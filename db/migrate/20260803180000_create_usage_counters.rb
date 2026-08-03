class CreateUsageCounters < ActiveRecord::Migration[8.1]
  def change
    create_table :usage_counters do |t|
      # Who the quota belongs to. Today this holds ApplicationController#
      # current_owner_token -- the same opaque per-session value as
      # resumes.owner_token (ADR-0007) -- so the limit is per browser session,
      # not per person. Deliberately a plain string and NOT a resumes reference:
      # the first quotaed action (a resume upload) happens before any Resume
      # exists, and when real auth lands this column takes a user id with no
      # migration. See ADR-0023.
      t.string :subject_token, null: false

      # One of Usage::Quota::ACTION_TYPES. A string rather than a Postgres enum
      # so adding an action type is an application change, not a migration.
      t.string :action_type, null: false

      # "day" for every row this app writes today. In the key from the start so
      # that adding a monthly quota is a constant plus a config value rather
      # than a migration on a table that by then has rows (ADR-0023).
      t.string :period, null: false

      # First date of the period the count covers -- for "day", the day itself.
      t.date :period_start, null: false

      t.integer :count, null: false, default: 0

      t.timestamps
    end

    # Both the lookup key and the conflict target for Usage::Counter.consume!'s
    # single-statement UPSERT. The uniqueness is what makes that increment
    # atomic across Puma threads and Solid Queue workers, so it is enforced by
    # the database rather than by a model validation.
    add_index :usage_counters, %i[subject_token action_type period period_start],
      unique: true, name: "index_usage_counters_on_subject_action_period"

    # Usage::Counter.purge_stale! scans on this.
    add_index :usage_counters, :period_start
  end
end
