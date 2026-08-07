# Issue #121. Replaces ADR-0007's owner_token placeholder with durable
# ownership now that #120 shipped mandatory accounts. NOT NULL, not nullable:
# Resume::Import sets user: in the same Resume.create! call that persists the
# rest of the row (ADR-0034), so there is no window in which a resume can
# exist without an owner -- unlike owner_token, which was written in a second
# update! after Resume::Import returned.
#
# No backfill: confirmed (ADR-0022, ADR-0026, and independently re-verified
# for this issue) that nothing has ever been deployed, so every resumes row in
# every environment is local test data. A local dev database with existing
# resumes will not survive this migration -- recreate it (bin/rails db:reset)
# rather than adding a migration-time backfill for data that was never
# supposed to be retained past a test run anyway.
class MigrateResumeOwnershipToUser < ActiveRecord::Migration[8.1]
  def change
    remove_index :resumes, :owner_token
    remove_index :resumes, :last_accessed_at
    remove_index :resumes, :created_at
    remove_column :resumes, :owner_token, :string

    # add_reference's default index (on user_id alone) replaces
    # index_resumes_on_owner_token above. The ORPHAN_PURGE_AFTER partial index
    # on created_at has no replacement -- there is no orphan tier anymore
    # (ADR-0034): a NOT NULL user_id makes that population empty by
    # construction, not just rare.
    add_reference :resumes, :user, null: false, foreign_key: true

    add_index :resumes, :last_accessed_at
  end
end
