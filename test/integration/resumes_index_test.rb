require "test_helper"

# Issue #121: root now points at resumes#index (a signed-in user's own resume
# history) instead of resumes#new (an empty upload form) -- this is the
# visible payoff of durable user_id ownership, so it gets its own coverage
# distinct from ResumeUploadsTest's owner-mismatch test.
class ResumesIndexTest < ActionDispatch::IntegrationTest
  # LlmCallGuard's test-env StubChat always returns "Stub Candidate" as the
  # extracted name regardless of file content, so both uploads share a name --
  # discriminate on resume_path instead, which is unique per row.
  test "the index lists only the current user's resumes, not another user's" do
    sign_in_as(users(:jordan))
    mine = upload_resume

    reset!
    sign_in_as(users(:alex))
    theirs = upload_resume

    get root_path
    assert_response :success
    assert_includes response.body, resume_path(theirs)
    assert_not_includes response.body, resume_path(mine)

    reset!
    sign_in_as(users(:jordan))
    get root_path
    assert_response :success
    assert_includes response.body, resume_path(mine)
    assert_not_includes response.body, resume_path(theirs)
  end

  # alex, not jordan: jordan owns the resumes(:one) fixture.
  test "a user with no resumes sees an empty state and a link to upload" do
    sign_in_as(users(:alex))

    get root_path

    assert_response :success
    assert_includes response.body, "haven't uploaded a resume yet"
    assert_select "a[href=?]", new_resume_path
  end

  private

  def upload_resume
    path = write_fixture({ note: "Stub Candidate, stub@example.com" }.to_json)
    post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
    Resume.last
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def write_fixture(content)
    path = Rails.root.join("tmp/resumes_index_test_#{SecureRandom.hex(4)}.json").to_s
    File.write(path, content)
    path
  end
end
