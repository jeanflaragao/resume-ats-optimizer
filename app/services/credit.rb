# Non-expiring credit balance and 30-day unlimited window (issue #122) -- the
# monetary layer on top of Usage::Quota's per-day abuse guard, not a
# replacement for it. See docs/adr/0035-credit-balance-and-unlimited-window.md
# for the spend side (available?/consume!): what triggers a debit, why the
# debit lives inside Resume::CachedOptimization rather than in a controller,
# and why cache expiry is a real charging boundary. See
# docs/adr/0036-stripe-checkout-for-credits-and-unlimited-window.md for the
# grant side (grant_credits!/grant_unlimited_days!, issue #123) -- every
# mutation of a user's balance lives in this one file regardless of which
# issue introduced it, so "what can change this number" stays a one-file
# audit.
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

    # Issue #123: a completed Stripe Checkout purchase, granted from the
    # webhook. Purely additive -- unlike consume!, there's no prior value to
    # race against, so a single UPDATE with `credits + ?` is already atomic
    # with no read step at all.
    def grant_credits!(user, amount)
      User.where(id: user.id).update_all([ "credits = credits + ?, updated_at = NOW()", amount ])
      nil
    end

    # Extends from the later of "now" or the current expiry, never just "now"
    # -- a second purchase while a window is still active must not discard
    # its unused remainder (a user who buys twice in one month would notice
    # losing days they already paid for). GREATEST/COALESCE make this one
    # atomic SQL expression rather than a Ruby read-then-write, for the same
    # reason consume! is raw SQL: two genuinely concurrent grants (e.g. two
    # real purchases landing at once) must not race each other's read of the
    # prior value.
    def grant_unlimited_days!(user, days)
      User.where(id: user.id).update_all([
        "unlimited_until = GREATEST(COALESCE(unlimited_until, ?), ?) + (? * INTERVAL '1 day'), updated_at = NOW()",
        Time.current, Time.current, days
      ])
      nil
    end

    private

      def unlimited?(user)
        user.unlimited_until.present? && Time.current < user.unlimited_until
      end
  end
end
