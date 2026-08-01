require "application_system_test_case"

class ResumeDownloadsTest < ApplicationSystemTestCase
  # Deliberately not waiting for the job to finish/broadcast here (system
  # tests run under the :test ActiveJob adapter, which queues without
  # executing) -- that path is already covered precisely, without real-browser
  # flakiness, by test/jobs/resume/optimized_pdf_job_test.rb's
  # assert_turbo_stream_broadcasts. This test exists to prove the real-browser
  # upload -> preview -> download click actually reaches a subscribed status
  # page, the one thing an integration test can't verify.
  test "clicking Download PDF after previewing reaches the generating-status page" do
    path = write_fixture({ note: "Stub Candidate, stub@example.com" }.to_json)

    visit new_resume_path
    attach_file "file", path
    click_on "Upload"

    fill_in "job_description_text", with: "We need a Ruby engineer."
    click_on "Preview optimized resume"

    assert_text "Optimized resume preview"

    click_on "Download PDF"

    assert_text "Preparing your download"
    assert_text "Generating your optimized resume PDF"
    assert_selector "turbo-cable-stream-source", visible: :all
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  private

  def write_fixture(content)
    path = Rails.root.join("tmp/resume_downloads_system_test_#{SecureRandom.hex(4)}.json").to_s
    File.write(path, content)
    path
  end
end
