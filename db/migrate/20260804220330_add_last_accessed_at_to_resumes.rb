class AddLastAccessedAtToResumes < ActiveRecord::Migration[8.1]
  def up
    add_column :resumes, :last_accessed_at, :datetime

    # Partial indexes matching Resume.purge_stale!'s two queries exactly (issue
    # #59): claimed resumes are scanned by last_accessed_at, never-claimed ones
    # by created_at. Each index only covers the rows its own query filters to,
    # keeping the (small, edge-case) orphan index tiny.
    add_index :resumes, :last_accessed_at, where: "owner_token IS NOT NULL"
    add_index :resumes, :created_at, where: "owner_token IS NULL"

    # Backfill for any resume that already has an owner_token but predates this
    # column (local/dev data -- ADR-0026 confirms no config/deploy.yml has ever
    # existed, so there is no production data to remediate here, same finding
    # as ADR-0022). Without this, such a row's last_accessed_at stays NULL
    # forever: NULL fails the `...cutoff` range comparison in the claimed-tier
    # half of Resume.purge_stale!, and the row doesn't match the orphan tier
    # either (owner_token is present), so it would never be purged by either
    # branch. created_at is the best available proxy for "last known access"
    # on a row with no other history.
    execute <<~SQL.squish
      UPDATE resumes SET last_accessed_at = created_at
      WHERE owner_token IS NOT NULL AND last_accessed_at IS NULL
    SQL
  end

  def down
    remove_index :resumes, :created_at
    remove_index :resumes, :last_accessed_at
    remove_column :resumes, :last_accessed_at
  end
end
