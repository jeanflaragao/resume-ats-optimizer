require "application_system_test_case"

# Guards against ApplicationSystemTestCase's setup/teardown (issue #57 / ADR-0013) being
# silently deleted -- if that happens, allow_forgery_protection quietly reverts to
# config/environments/test.rb's environment-wide false and every system test's CSRF
# verification stops being exercised, with no failure to signal it. Asserts the mechanism
# is present, not the formaction bug itself, so this survives #47's rewrite of the actual
# form-submitting controllers unchanged.
class ForgeryProtectionTest < ApplicationSystemTestCase
  test "forgery protection is enabled for the duration of a system test" do
    assert ActionController::Base.allow_forgery_protection,
      "system tests must enable forgery protection (see ApplicationSystemTestCase) to keep " \
      "catching CSRF bugs like the formaction issue from #17/#18 -- see issue #57"
  end
end
