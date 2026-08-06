# Resolves an OmniAuth auth hash to a User, implementing the identity
# resolution decided in issue #120: a User is identified by verified email,
# not by (provider, uid) alone, so a second provider added later links to the
# same account rather than creating a duplicate with its own (zero) credit
# balance once #122 makes credits real.
module Authentication
  class FindOrCreateUser
    # Google is not expected to ever send an unverified email through this
    # scope, but the field exists on the auth hash specifically to be checked,
    # not trusted blindly — resolving identity by email requires the email be
    # real.
    class UnverifiedEmailError < StandardError; end

    def self.call(auth:)
      new(auth).call
    end

    def initialize(auth)
      @auth = auth
    end

    def call
      identity&.user || link_or_create_user
    end

    private

    attr_reader :auth

    def identity
      @identity ||= Identity.find_by(provider: auth.provider, uid: auth.uid)
    end

    def link_or_create_user
      raise UnverifiedEmailError unless email_verified?

      ActiveRecord::Base.transaction do
        user = User.find_or_create_by!(email: auth.info.email) do |new_user|
          new_user.name = auth.info.name
          new_user.avatar_url = auth.info.image
        end
        user.identities.create!(provider: auth.provider, uid: auth.uid)
        user
      end
    end

    def email_verified?
      ActiveModel::Type::Boolean.new.cast(auth.extra&.raw_info&.email_verified)
    end
  end
end
