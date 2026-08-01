require "test_helper"

class ResumeUploadsTest < ActionDispatch::IntegrationTest
  test "uploading a valid file persists a Resume and redirects to its confirmation page" do
    # LlmCallGuard defaults to stub mode in test (ENABLE_REAL_LLM_CALLS unset), whose
    # StubChat returns this exact name/email — include them in the source file so
    # Resume::Extractors::Llm's own fidelity verification doesn't drop them.
    path = write_fixture({ note: "Stub Candidate, stub@example.com" }.to_json)

    assert_difference "Resume.count", 1 do
      post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
    end

    resume = Resume.last
    assert_redirected_to resume_path(resume)
    assert_equal "llm", resume.source

    follow_redirect!
    assert_response :success
    assert_includes response.body, "Stub Candidate"
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "no file selected re-renders the form with an error and creates nothing" do
    assert_no_difference "Resume.count" do
      post resumes_path, params: {}
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "choose a file"
  end

  test "an unsupported file format re-renders the form with an error and creates nothing" do
    path = Rails.root.join("tmp/resume_upload_test_#{SecureRandom.hex(4)}.txt").to_s
    File.write(path, "hello")

    assert_no_difference "Resume.count" do
      post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "text/plain") }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "couldn&#39;t process"
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "a rollback during import re-renders the form with an error and creates nothing" do
    path = write_fixture({ note: "irrelevant" }.to_json)
    invalid_error = ActiveRecord::RecordInvalid.new(Resume.new)
    original_call = Resume::Import.method(:call)
    Resume::Import.define_singleton_method(:call) { |**| raise invalid_error }

    assert_no_difference "Resume.count" do
      post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "couldn&#39;t process"
  ensure
    Resume::Import.define_singleton_method(:call, original_call)
    File.delete(path) if path && File.exist?(path)
  end

  test "uploading a file over MAX_UPLOAD_BYTES re-renders the form with an error and creates nothing" do
    oversized = Tempfile.new([ "oversized", ".json" ])
    oversized.write("x" * (ResumesController::MAX_UPLOAD_BYTES + 1))
    oversized.flush

    assert_no_difference "Resume.count" do
      post resumes_path, params: {
        file: Rack::Test::UploadedFile.new(oversized.path, "application/json", original_filename: "oversized.json")
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "too large"
  ensure
    oversized&.close!
  end

  test "uploading a file exactly at MAX_UPLOAD_BYTES succeeds" do
    # A file at the exact limit must not be rejected by the size guard.
    # Pad valid JSON with trailing whitespace so bytesize == MAX_UPLOAD_BYTES exactly.
    valid_base = '{"note":"Stub Candidate, stub@example.com"}'
    padding = " " * (ResumesController::MAX_UPLOAD_BYTES - valid_base.bytesize)
    at_limit = Tempfile.new([ "at_limit", ".json" ])
    at_limit.write(valid_base + padding)
    at_limit.flush

    assert_difference "Resume.count", 1 do
      post resumes_path, params: {
        file: Rack::Test::UploadedFile.new(at_limit.path, "application/json", original_filename: "at_limit.json")
      }
    end

    assert_redirected_to resume_path(Resume.last)
  ensure
    at_limit&.close!
  end

  test "a resume is only visible to the session that uploaded it" do
    path = write_fixture({ note: "Stub Candidate, stub@example.com" }.to_json)
    post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
    resume = Resume.last

    reset!

    get resume_path(resume)
    assert_response :not_found
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  private

  def write_fixture(content)
    path = Rails.root.join("tmp/resume_upload_test_#{SecureRandom.hex(4)}.json").to_s
    File.write(path, content)
    path
  end
end
