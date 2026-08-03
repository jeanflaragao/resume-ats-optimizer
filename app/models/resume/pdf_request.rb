# The job description a download was requested against, held out of the queue.
#
# Issue #76: Resume::OptimizedPdfJob used to take job_description_text as an
# Active Job argument, and in production Solid Queue serialises arguments into
# solid_queue_jobs.arguments -- a plain text column, with no retention bound at
# all for jobs that failed. This table replaces that with a reference: the queue
# carries an id, the text lives here encrypted, and it is deleted on success or
# purged on a schedule. ADR-0022 has the reasoning.
class Resume::PdfRequest < ApplicationRecord
  # Non-deterministic. The text is never looked up by value, and deterministic
  # encryption would produce identical ciphertext for identical postings --
  # which would reveal that two users are applying to the same job, the exact
  # inference issue #76 wants to avoid. support_unencrypted_data is deliberately
  # left off: this table is new, so there is no plaintext to read back.
  encrypts :text

  belongs_to :resume

  # How long a request may sit on disk before it is deleted unread.
  #
  # NOT inherited from Resume::CachedOptimization::CACHE_TTL / ADR-0012 -- that
  # window measures how long a *finished artifact* stays downloadable, which is
  # a different quantity from how long we retain the *input* to a job that
  # failed or has not started. Derived instead from the two sides that actually
  # bound it:
  #
  #   Privacy (shorter is better): the floor is worst-case enqueue-to-finish.
  #   Resume::CachedOptimization measured the pipeline at 0.25s + 4.5s per
  #   experience, so a nine-experience resume runs ~40.75s, and ~81.5s if it
  #   also waits out that class's lock. Anything under ~2 minutes would start
  #   deleting live work.
  #
  #   Operations (longer is better): with three worker threads
  #   (config/queue.yml) a request only sits unstarted this long under a real
  #   backlog -- roughly 190 queued downloads at the measured ~14s median, or a
  #   far smaller queue while the Anthropic API is degraded. Fifteen minutes is
  #   ~11x the worst single-job duration measured above, which covers that
  #   without keeping anything overnight.
  #
  # Deliberately NOT sized for manual retry of a failed job. A deterministic
  # failure -- Resume::Pdf::UnrenderableCharacterError still ends every download
  # for a CJK, Hebrew, Arabic or Devanagari name (ADR-0018) -- is noticed hours
  # or days later, never inside any window worth keeping the text for. The
  # supported recovery is the user generating a new download, which writes a new
  # request; retaining this one for an operator would be paying in exposure for
  # a workflow nobody uses.
  PURGE_AFTER = 15.minutes

  # Called from config/recurring.yml. destroy_all rather than delete_all: the
  # row count is tiny (successful jobs delete their own), and going through the
  # model keeps any future dependent behaviour honest.
  def self.purge_stale!
    where(created_at: ...PURGE_AFTER.ago).destroy_all
  end
end
