require "application_system_test_case"

class ResumeDownloadsTest < ApplicationSystemTestCase
  # Deliberately not waiting for the job to finish/broadcast here (system
  # tests run under the :test ActiveJob adapter, which queues without
  # executing) -- that path is already covered precisely, without real-browser
  # flakiness, by test/jobs/resume/optimized_pdf_job_test.rb's
  # assert_turbo_stream_broadcasts. This test exists to prove the real-browser
  # check match -> preview -> download click actually works end to end, with
  # every one of those forms (turbo_stream-submitted since issue #47) carrying
  # a real, verified CSRF token (issue #57 / ADR-0013) -- the one thing an
  # integration test can't verify, since it never renders real forms or
  # carries real tokens.
  test "checking match, previewing, and downloading all succeed with real CSRF tokens" do
    path = write_fixture({ note: "Stub Candidate, stub@example.com" }.to_json)

    visit new_resume_path
    attach_file "file", path
    click_on "Upload"

    # Whitespace-only satisfies the textarea's HTML5 `required` attribute client-side (it's a
    # non-empty value) but still fails Rails' server-side `.blank?` check -- this is what lets a
    # real browser reach JobDescriptionsController's error branch at all, proving the
    # turbo_stream.update("flash", ...) action (issue #47) actually renders in a live,
    # Turbo-driven browser, not just in integration tests that never carry real forms.
    fill_in "job_description_text", with: "   "
    click_on "Check match"

    assert_text "Please paste a job description."

    fill_in "job_description_text", with: "We need a Ruby engineer."
    click_on "Check match"

    assert_text "Match results"

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
