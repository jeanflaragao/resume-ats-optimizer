require "test_helper"
require "fugit"

# Structural assertions about config/recurring.yml, in the same spirit as
# test/config/cache_test.rb. A recurring task is configured as a string and
# validated only at runtime by a process that does not exist yet (issue #48, no
# config/deploy.yml), so a typo in the class name or the schedule would ship and
# then silently never run -- which for purge_stale_pdf_requests means job
# descriptions accumulating on disk with no bound, the exact issue #76 defect.
class RecurringConfigTest < ActiveSupport::TestCase
  setup { @production = Rails.application.config_for(:recurring, env: "production") }

  test "the pdf request purge is scheduled and its command resolves" do
    task = @production[:purge_stale_pdf_requests]

    assert_not_nil task, "purge_stale_pdf_requests is missing from config/recurring.yml"
    assert_equal "Resume::PdfRequest.purge_stale!", task[:command]
    assert_respond_to Resume::PdfRequest, :purge_stale!
  end

  test "every recurring schedule parses" do
    @production.each do |name, task|
      assert_not_nil Fugit.parse(task[:schedule]), "#{name} has an unparseable schedule: #{task[:schedule]}"
    end
  end

  # The purge has to run more often than the window it enforces, or the window
  # is really PURGE_AFTER plus the gap between runs.
  test "the purge runs more often than the retention window it enforces" do
    cron = Fugit.parse(@production[:purge_stale_pdf_requests][:schedule])
    first = cron.next_time(Time.current)
    interval = cron.next_time(first.to_t).to_t - first.to_t

    assert_operator interval, :<, Resume::PdfRequest::PURGE_AFTER.to_i
  end
end
