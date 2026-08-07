require "test_helper"

class Payments::ConfigGuardTest < ActiveSupport::TestCase
  setup do
    @original_env = Payments::ConfigGuard::REQUIRED_ENV_VARS.to_h { |var| [ var, ENV[var] ] }
    @original_dummy_secret = ENV["SECRET_KEY_BASE_DUMMY"]
    ENV.delete("SECRET_KEY_BASE_DUMMY")
  end

  teardown do
    @original_env.each { |var, value| value.nil? ? ENV.delete(var) : ENV[var] = value }
    ENV["SECRET_KEY_BASE_DUMMY"] = @original_dummy_secret
    ENV.delete("SECRET_KEY_BASE_DUMMY") if @original_dummy_secret.nil?
  end

  test "validate_configuration! is a no-op outside production" do
    Payments::ConfigGuard::REQUIRED_ENV_VARS.each { |var| ENV.delete(var) }

    assert_nothing_raised do
      Payments::ConfigGuard.validate_configuration!(env: ActiveSupport::StringInquirer.new("development"))
      Payments::ConfigGuard.validate_configuration!(env: ActiveSupport::StringInquirer.new("test"))
    end
  end

  test "production refuses to boot when any required var is unset" do
    Payments::ConfigGuard::REQUIRED_ENV_VARS.each do |missing|
      set_all_vars
      ENV.delete(missing)

      error = assert_raises(Payments::ConfigGuard::ConfigurationError) { validate_production! }
      assert_includes error.message, missing
    end
  end

  test "production boots when every required var is set" do
    set_all_vars

    assert_nothing_raised { validate_production! }
  end

  # Dockerfile:50 boots Rails under RAILS_ENV=production to precompile assets,
  # with no deploy environment to read and no requests to serve. Without this
  # exemption the image build would fail (ADR-0020's carve-out, same one every
  # other guard in this app uses).
  test "the assets:precompile boot is exempt even with nothing configured" do
    Payments::ConfigGuard::REQUIRED_ENV_VARS.each { |var| ENV.delete(var) }
    ENV["SECRET_KEY_BASE_DUMMY"] = "1"

    assert_nothing_raised { validate_production! }
  end

  private

  def set_all_vars(value = "test_value")
    Payments::ConfigGuard::REQUIRED_ENV_VARS.each { |var| ENV[var] = value }
  end

  def validate_production!
    Payments::ConfigGuard.validate_configuration!(env: ActiveSupport::StringInquirer.new("production"))
  end
end
