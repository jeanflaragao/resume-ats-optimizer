class AddCreditsToUsers < ActiveRecord::Migration[8.1]
  def change
    # Two free credits on signup (issue #122) — a DB default, not a
    # post-create update!, for the same reason resumes.user_id is set inside
    # Resume::Import's single create! call (ADR-0034): a User row can never
    # transiently exist without its balance. NOT NULL because "no balance yet"
    # is not a state this column is allowed to represent — zero is a real,
    # meaningful balance, nil would be a bug waiting to be dereferenced.
    add_column :users, :credits, :integer, null: false, default: 2

    # Nullable: nil means "no active unlimited window", not zero/epoch. No
    # index — gated on Time.current < unlimited_until for a single row
    # (Current.user) at a time, never queried in bulk.
    add_column :users, :unlimited_until, :datetime
  end
end
