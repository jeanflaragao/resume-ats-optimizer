class Resume < ApplicationRecord
  has_many :experiences, -> { order(:position) }, dependent: :destroy
  has_many :educations, -> { order(:position) }, dependent: :destroy
  has_many :pdf_requests, dependent: :destroy

  # Issue #59. #76 bounded a pasted job description to 15 minutes
  # (Resume::PdfRequest::PURGE_AFTER) while the candidate's own name, email,
  # phone and work history sat here with no bound at all -- see ADR-0026.

  # A claimed resume (owner_token present) might still be revisited by
  # whoever holds that browser's session cookie, no matter how old -- so it's
  # only stale once nothing has read it in this long. Measured from
  # last_accessed_at, not created_at: someone who returns on day 6 to target
  # another job should not lose it on day 7.
  LAST_ACCESSED_PURGE_AFTER = 7.days

  # owner_token is only ever set once, in ResumesController#create, with no
  # retry or re-claim path. A row that never got claimed (owner_token nil)
  # can never satisfy find_owned_resume! for any session -- current_owner_token
  # is never nil -- so it is unreachable from the moment it's created. There is
  # no "last access" to measure from; ORPHAN_PURGE_AFTER runs from created_at.
  ORPHAN_PURGE_AFTER = 24.hours

  # Called from Resume::PurgeStaleJob. in_batches.destroy_all rather than a
  # bare destroy_all: unlike Resume::PdfRequest (which stays near-zero because
  # a successful download deletes its own row), resumes accumulate for the
  # full width of LAST_ACCESSED_PURGE_AFTER, so the stale set can be large
  # enough that loading it into memory in one shot is the wrong default. Still
  # destroy_all underneath, not delete_all: experiences/educations have no
  # ON DELETE CASCADE at the DB level (unlike resume_pdf_requests), so a raw
  # delete would raise a foreign-key violation on the first stale resume with
  # any children. destroy_all runs dependent: :destroy per batch instead.
  #
  # Returns { claimed:, orphan: } counts so the job can log them -- without
  # this, there's no way to tell from the logs whether the purge ran at all,
  # let alone whether it over- or under-deleted (issue #59's acceptance
  # criterion). Each scope's count is read before destroying it, since
  # in_batches.destroy_all itself returns the batch enumerator, not a count.
  def self.purge_stale!
    claimed = where.not(owner_token: nil).where(last_accessed_at: ...LAST_ACCESSED_PURGE_AFTER.ago)
    claimed_count = claimed.count
    claimed.in_batches.destroy_all

    orphaned = where(owner_token: nil).where(created_at: ...ORPHAN_PURGE_AFTER.ago)
    orphaned_count = orphaned.count
    orphaned.in_batches.destroy_all

    { claimed: claimed_count, orphan: orphaned_count }
  end
end
