require "test_helper"

class Resume::PurgeStaleJobTest < ActiveJob::TestCase
  test "purges stale resumes via Resume.purge_stale! and logs the destroyed count" do
    stale = Resume.create!(user: users(:jordan), last_accessed_at: Resume::LAST_ACCESSED_PURGE_AFTER.ago - 1.minute)
    recent = Resume.create!(user: users(:alex), last_accessed_at: Time.current)

    log_output = with_captured_log { Resume::PurgeStaleJob.perform_now }

    assert_not Resume.exists?(stale.id)
    assert Resume.exists?(recent.id)
    assert_includes log_output, "purged 1 resume(s)"
  end

  private

  def with_captured_log
    original_logger = Rails.logger
    io = StringIO.new
    Rails.logger = Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original_logger
  end
end
