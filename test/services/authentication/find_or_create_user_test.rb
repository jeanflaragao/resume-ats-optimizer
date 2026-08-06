require "test_helper"

class Authentication::FindOrCreateUserTest < ActiveSupport::TestCase
  def auth_hash(uid:, email:, email_verified: true, name: "Test User")
    OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: uid,
      info: { email: email, name: name, image: "https://example.com/avatar.png" },
      extra: { raw_info: { email_verified: email_verified } }
    )
  end

  test "creates a new user and identity from a fresh auth hash" do
    assert_difference [ "User.count", "Identity.count" ], 1 do
      user = Authentication::FindOrCreateUser.call(auth: auth_hash(uid: "1", email: "new.user@example.com"))

      assert_equal "new.user@example.com", user.email
      assert_equal "Test User", user.name
    end
  end

  test "a second sign-in with the same provider and uid reuses the same user, not a duplicate" do
    first_user = Authentication::FindOrCreateUser.call(auth: auth_hash(uid: "2", email: "returning@example.com"))

    assert_no_difference [ "User.count", "Identity.count" ] do
      second_user = Authentication::FindOrCreateUser.call(auth: auth_hash(uid: "2", email: "returning@example.com"))

      assert_equal first_user, second_user
    end
  end

  test "a differing-case email still resolves to the same user, since email is normalized" do
    first_user = Authentication::FindOrCreateUser.call(auth: auth_hash(uid: "3", email: "Case@Example.com"))

    assert_no_difference "User.count" do
      second_user = Authentication::FindOrCreateUser.call(auth: auth_hash(uid: "4", email: "case@example.com"))

      assert_equal first_user, second_user
    end
  end

  test "raises UnverifiedEmailError and creates nothing when Google reports the email as unverified" do
    assert_no_difference [ "User.count", "Identity.count" ] do
      assert_raises(Authentication::FindOrCreateUser::UnverifiedEmailError) do
        Authentication::FindOrCreateUser.call(auth: auth_hash(uid: "5", email: "unverified@example.com", email_verified: false))
      end
    end
  end
end
