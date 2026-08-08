class User < ApplicationRecord
  has_many :sessions, dependent: :destroy
  has_many :identities, dependent: :destroy
  # No dependent: -- there is no account-deletion feature anywhere in the app
  # (sign-out only destroys a Session). Destroying a User that still owns
  # resumes raises resumes.user_id's FK violation rather than cascading,
  # which is the right default for data issue #121/ADR-0034 treats as a
  # permanent liability, not something to silently discard.
  has_many :resumes
  # No dependent: here either, for the same reason -- a payment_grants row is
  # the audit trail for real money already received (issue #123) and must
  # survive exactly as long as credits/unlimited_until do.
  has_many :payment_grants, class_name: "Payments::Grant"

  normalizes :email, with: ->(email) { email.strip.downcase }

  validates :email, presence: true, uniqueness: true
end
