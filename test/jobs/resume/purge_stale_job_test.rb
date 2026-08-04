require "test_helper"

class Resume::PurgeStaleJobTest < ActiveJob::TestCase
  test "purges stale resumes via Resume.purge_stale! and logs the destroyed counts" do
    stale_claimed = Resume.create!(owner_token: "token-a", last_accessed_at: Resume::LAST_ACCESSED_PURGE_AFTER.ago - 1.minute)
    stale_orphan = Resume.create!(owner_token: nil, created_at: Resume::ORPHAN_PURGE_AFTER.ago - 1.minute)
    recent = Resume.create!(owner_token: "token-b", last_accessed_at: Time.current)

    log_output = with_captured_log { Resume::PurgeStaleJob.perform_now }

    assert_not Resume.exists?(stale_claimed.id)
    assert_not Resume.exists?(stale_orphan.id)
    assert Resume.exists?(recent.id)
    assert_includes log_output, "purged 1 claimed, 1 orphaned resume(s)"
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
