require "test_helper"

# Issue #122: the credit balance must be visible, and the Preview/Download
# buttons must say what a click will cost before the click happens -- not
# just be enforced server-side after the fact.
class CreditUiTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:jordan))
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown { Rails.cache = @original_cache }

  test "the account bar shows the signed-in user's remaining credits" do
    users(:jordan).update!(credits: 2, unlimited_until: nil)

    get root_path

    assert_includes response.body, "2 credits remaining"
  end

  test "the account bar shows the unlimited window instead of a balance while it's active" do
    users(:jordan).update!(credits: 0, unlimited_until: Date.new(2026, 9, 1).end_of_day)

    get root_path

    assert_includes response.body, "Unlimited until September 01, 2026"
  end

  test "the preview button has no cost label until a job description is known" do
    resume = upload_resume

    get resume_path(resume)

    assert_includes response.body, 'value="Preview optimized resume"'
  end

  test "the preview button is labeled with its cost once a job description is checked" do
    resume = upload_resume
    users(:jordan).update!(credits: 2, unlimited_until: nil)

    post resume_job_description_path(resume), params: { job_description_text: "We need a Ruby engineer." }

    assert_includes response.body, "Preview optimized resume — uses 1 credit"
  end

  test "the preview button is disabled and says so once credits run out" do
    resume = upload_resume
    users(:jordan).update!(credits: 0, unlimited_until: nil)

    post resume_job_description_path(resume), params: { job_description_text: "We need a Ruby engineer." }

    assert_includes response.body, "Preview optimized resume — out of credits"
    assert_match(/<input[^>]*value="Preview optimized resume — out of credits"[^>]*disabled="disabled"/, response.body)
  end

  test "the download button says free once the same pair has already been previewed" do
    resume = upload_resume
    users(:jordan).update!(credits: 2, unlimited_until: nil)

    post resume_preview_path(resume), params: { job_description_text: "We need a Ruby engineer." }

    assert_includes response.body, "Download PDF — free, already generated"
  end

  private

  def upload_resume
    path = write_fixture({ note: "Stub Candidate, stub@example.com" }.to_json)
    post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
    Resume.last.tap do |resume|
      resume.experiences.create!(company: "Acme", title: "Engineer", bullets: [ "Built REST APIs" ], position: 1)
    end
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def write_fixture(content)
    path = Rails.root.join("tmp/credit_ui_test_#{SecureRandom.hex(4)}.json").to_s
    File.write(path, content)
    path
  end
end
