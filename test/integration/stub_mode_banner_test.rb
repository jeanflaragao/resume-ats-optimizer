require "test_helper"

# The counterpart to LlmCallGuardTest's stub_mode_banner? unit cases: those
# prove the predicate is right, this proves the layout actually asks it.
# Deleting the render line from app/views/layouts/application.html.erb leaves
# every predicate test passing.
class StubModeBannerTest < ActionDispatch::IntegrationTest
  # Stub-mode-outside-local is unreachable in the test environment by design
  # (Rails.env.local?), so the predicate is stubbed rather than the environment
  # faked. define_singleton_method rather than Minitest::Mock, matching
  # LlmCallGuardTest#with_recording_chat.
  def with_stub_mode_banner(visible)
    original = LlmCallGuard.method(:stub_mode_banner?)
    LlmCallGuard.define_singleton_method(:stub_mode_banner?) { |**| visible }
    yield
  ensure
    LlmCallGuard.define_singleton_method(:stub_mode_banner?, original)
  end

  test "the layout announces stub mode when the guard says it should be visible" do
    with_stub_mode_banner(true) { get root_path }

    assert_response :success
    assert_includes response.body, "Demo mode"
    assert_includes response.body, "placeholder text"
  end

  test "the layout stays silent when real calls are being made" do
    with_stub_mode_banner(false) { get root_path }

    assert_response :success
    assert_not_includes response.body, "Demo mode"
  end
end
