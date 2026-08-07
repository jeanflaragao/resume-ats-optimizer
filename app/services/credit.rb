# Non-expiring credit balance and 30-day unlimited window (issue #122) -- the
# monetary layer on top of Usage::Quota's per-day abuse guard, not a
# replacement for it. See docs/adr/0035-credit-balance-and-unlimited-window.md
# for the full model: what triggers a debit, why the debit lives inside
# Resume::CachedOptimization rather than in a controller, and why cache expiry
# is a real charging boundary.
class Credit
  class << self
    # Permission to start, never itself a charge. True inside an active
    # unlimited window, or with a positive balance. Called before
    # enforce_quota! in ResumesController#create, PreviewsController#create,
    # and DownloadsController#create -- the same relative position
    # Resume::Pdf.guard_renderable! already has (ADR-0025), extended to a
    # second gate.
    def available?(user)
      unlimited?(user) || user.credits.positive?
    end

    # The actual spend -- called from exactly one place, the winning-
    # computation branch of Resume::CachedOptimization#call, after a genuine
    # cache miss has already been computed and cached. Free inside an active
    # unlimited window (checked fresh here, not from an earlier gate read --
    # a download's window can expire between enqueue and the job actually
    # running).
    #
    # Deliberately not reserve-then-confirm: by the time this runs, the LLM
    # work already happened -- that's what makes it a miss. There is nothing
    # left to reserve or release, so this is an unconditional atomic
    # decrement -- a single UPDATE, not User#decrement! (read-modify-write in
    # Ruby, the same lost-update failure mode Usage::Counter.consume!'s
    # upsert_all exists to avoid). No `WHERE credits > 0` guard: the gate
    # above already established headroom before the costly work started, and
    # withholding an already-paid-for result over a balance race would be
    # strictly worse than letting a concurrent, genuinely-distinct request
    # take the balance to -1. Same direction as ADR-0019's "overcounts rather
    # than undercounts", now applied to money -- see the ADR for the full
    # reasoning.
    def consume!(user)
      return if unlimited?(user)

      User.where(id: user.id).update_all("credits = credits - 1, updated_at = NOW()")
      nil
    end

    private

      def unlimited?(user)
        user.unlimited_until.present? && Time.current < user.unlimited_until
      end
  end
end
