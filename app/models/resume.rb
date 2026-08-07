class Resume < ApplicationRecord
  belongs_to :user
  has_many :experiences, -> { order(:position) }, dependent: :destroy
  has_many :educations, -> { order(:position) }, dependent: :destroy
  has_many :pdf_requests, dependent: :destroy

  # Issue #59. #76 bounded a pasted job description to 15 minutes
  # (Resume::PdfRequest::PURGE_AFTER) while the candidate's own name, email,
  # phone and work history sat here with no bound at all -- see ADR-0026,
  # superseded by ADR-0034 for the reasoning below.

  # One month from the owner's last visit -- not from upload, and not tied to
  # credit exhaustion (issue #122's balance never expires, so a user who buys
  # credits, uses a few, and disappears would otherwise have their PII
  # retained forever). last_accessed_at (issue #59) is the signal that
  # actually reflects use: someone who returns on day 20 to target another job
  # should not lose their resume on day 30 -- err, day 1.
  #
  # There is no second, "unclaimed" tier the way ADR-0026 had one. That tier
  # existed because owner_token was written in a second update! after
  # Resume::Import returned -- a crash between the two left a row with no
  # owner, reachable by no session, ever. resumes.user_id is NOT NULL and set
  # inside the same Resume.create! call that persists everything else
  # (Resume::Import, ADR-0034), so that row can no longer exist even
  # transiently. A single tier is not a simplification made for its own sake;
  # it reflects a population (ownerless resumes) that is now empty by
  # construction.
  LAST_ACCESSED_PURGE_AFTER = 1.month

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
  # Never reaches users or usage_counters. A purged owner's identity and their
  # issue #122 credit balance are a permanent liability -- someone who returns
  # after a year finds their remaining credits and starts fresh -- not
  # something a resume-retention purge is allowed to touch. This method's
  # where clause only ever selects from resumes, so that boundary holds by
  # construction; ResumeTest asserts it directly rather than relying on that
  # being obvious from reading the query.
  #
  # Returns the destroyed count so the job can log it -- without this,
  # there's no way to tell from the logs whether the purge ran at all, let
  # alone how much it deleted (issue #59's acceptance criterion). Read before
  # destroying, since in_batches.destroy_all itself returns the batch
  # enumerator, not a count.
  def self.purge_stale!
    stale = where(last_accessed_at: ...LAST_ACCESSED_PURGE_AFTER.ago)
    count = stale.count
    stale.in_batches.destroy_all
    count
  end
end
