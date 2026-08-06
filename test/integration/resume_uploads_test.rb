require "test_helper"

class ResumeUploadsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(users(:jordan)) }

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

  test "uploading a malformed PDF re-renders the form with an error and creates nothing" do
    malformed = Tempfile.new([ "malformed", ".pdf" ])
    malformed.write("this is not a PDF")
    malformed.flush

    log_output = with_captured_log do
      assert_no_difference "Resume.count" do
        post resumes_path, params: {
          file: Rack::Test::UploadedFile.new(malformed.path, "application/pdf", original_filename: "malformed.pdf")
        }
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "couldn&#39;t read"
    # PII guard: log must not contain the file's raw content
    assert_not_includes log_output, "this is not a PDF"
  ensure
    malformed&.close!
  end

  test "an unreadable JSON file re-renders the form with an error and creates nothing" do
    # Resume::Extractors::JsonMapper::InvalidJsonError is only raised by the
    # "regex" strategy (JsonMapper.call), not by the default "llm" strategy
    # (Extractors::Llm reads JSON as raw text for fidelity verification, not
    # as structured JSON). The rescue clause is still present for defense in
    # depth — tested here via injection, same pattern as the RecordInvalid test.
    path = write_fixture({ note: "irrelevant" }.to_json)
    original_import = Resume::Import.method(:call)
    Resume::Import.define_singleton_method(:call) { |**| raise Resume::Extractors::JsonMapper::InvalidJsonError, "Could not parse /tmp/test.json as JSON: unexpected token" }

    log_output = with_captured_log do
      assert_no_difference "Resume.count" do
        post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "couldn&#39;t read"
    assert_not_includes log_output, "unexpected token"
  ensure
    Resume::Import.define_singleton_method(:call, original_import)
    File.delete(path) if path && File.exist?(path)
  end

  test "an LLM daily limit error on upload redirects with an actionable message" do
    path = write_fixture({ note: "irrelevant" }.to_json)
    original_import = Resume::Import.method(:call)
    Resume::Import.define_singleton_method(:call) { |**| raise LlmCallGuard::DailyLimitExceededError, "Daily LLM call cap (10) exceeded" }

    assert_no_difference "Resume.count" do
      post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, "processing limit"
  ensure
    Resume::Import.define_singleton_method(:call, original_import)
    File.delete(path) if path && File.exist?(path)
  end

  test "an LLM service error on upload redirects with an actionable message and does not log PII" do
    path = write_fixture({ note: "irrelevant" }.to_json)
    secret_jd = "SECRET RESUME CONTENT THAT MUST NOT BE LOGGED"
    original_import = Resume::Import.method(:call)
    Resume::Import.define_singleton_method(:call) { |**| raise RubyLLM::ServiceUnavailableError.new(secret_jd) }

    log_output = with_captured_log do
      assert_no_difference "Resume.count" do
        post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
      end
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, "unavailable"
    # PII guard: the exception message (simulating a response body with user content) must not land in logs
    assert_not_includes log_output, secret_jd
  ensure
    Resume::Import.define_singleton_method(:call, original_import)
    File.delete(path) if path && File.exist?(path)
  end

  test "an LLM service error logs the HTTP status code alongside the exception class" do
    path = write_fixture({ note: "irrelevant" }.to_json)
    fake_response = Struct.new(:status, :body).new(529, nil)
    original_import = Resume::Import.method(:call)
    Resume::Import.define_singleton_method(:call) { |**| raise RubyLLM::OverloadedError.new(fake_response, "overloaded") }

    log_output = with_captured_log do
      post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
    end

    assert_redirected_to root_path
    assert_includes log_output, "529"
  ensure
    Resume::Import.define_singleton_method(:call, original_import)
    File.delete(path) if path && File.exist?(path)
  end

  test "a Faraday connection error logs the exception class and no status when there is no HTTP response" do
    path = write_fixture({ note: "irrelevant" }.to_json)
    original_import = Resume::Import.method(:call)
    Resume::Import.define_singleton_method(:call) { |**| raise Faraday::ConnectionFailed.new("connection refused") }

    log_output = with_captured_log do
      post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
    end

    assert_redirected_to root_path
    assert_includes log_output, "Faraday::ConnectionFailed"
    assert_not_includes log_output, "HTTP"
  ensure
    Resume::Import.define_singleton_method(:call, original_import)
    File.delete(path) if path && File.exist?(path)
  end

  test "a resume is only visible to the session that uploaded it" do
    path = write_fixture({ note: "Stub Candidate, stub@example.com" }.to_json)
    post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
    resume = Resume.last

    reset!
    sign_in_as(users(:alex))

    get resume_path(resume)
    assert_response :not_found
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  test "uploading a valid file sets last_accessed_at" do
    path = write_fixture({ note: "Stub Candidate, stub@example.com" }.to_json)
    post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }

    assert_not_nil Resume.last.last_accessed_at
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  # Issue #59: find_owned_resume! (the shared lookup #show routes through)
  # must bump last_accessed_at so Resume.purge_stale! knows the resume is
  # still in use -- but must not touch updated_at, or every view would
  # invalidate Resume::CachedOptimization's cache (ADR-0021, ADR-0026).
  test "viewing a resume bumps last_accessed_at without touching updated_at" do
    path = write_fixture({ note: "Stub Candidate, stub@example.com" }.to_json)
    post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
    resume = Resume.last
    original_updated_at = resume.updated_at
    original_last_accessed_at = resume.last_accessed_at

    travel 1.hour do
      get resume_path(resume)
    end

    resume.reload
    assert_operator resume.last_accessed_at, :>, original_last_accessed_at
    assert_equal original_updated_at, resume.updated_at
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  private

  def write_fixture(content)
    path = Rails.root.join("tmp/resume_upload_test_#{SecureRandom.hex(4)}.json").to_s
    File.write(path, content)
    path
  end

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
