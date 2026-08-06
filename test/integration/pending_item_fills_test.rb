require "test_helper"

class PendingItemFillsTest < ActionDispatch::IntegrationTest
  setup { sign_in_as(users(:jordan)) }

  test "the show page renders a pending item, and it's gone from a fresh page load after being filled in" do
    resume = upload_resume_with_drops

    get resume_path(resume)
    assert_response :success
    assert_includes response.body, "appear in your original document"

    post resume_pending_items_path(resume), params: { pending_item: { scope: "resume", field: "name", value: "Jane Doe" } }
    assert_response :redirect
    post resume_pending_items_path(resume), params: { pending_item: { scope: "resume", field: "email", value: "jane@example.com" } }
    assert_response :redirect

    get resume_path(resume)
    assert_response :success
    assert_includes response.body, "Jane Doe"
    assert_not_includes response.body, "didn't appear in your original document"
  end

  test "fills a resume-scoped dropped field and removes it from pending_items" do
    resume = upload_resume_with_drops

    assert_includes resume.pending_items.map { |item| item["field"] }, "name"

    post resume_pending_items_path(resume), params: { pending_item: { scope: "resume", field: "name", value: "Jane Doe" } }

    assert_response :redirect
    resume.reload
    assert_equal "Jane Doe", resume.name
    assert_not_includes resume.pending_items.map { |item| item["field"] }, "name"
  end

  test "fills an experience-scoped field and removes it from that experience's pending_items only" do
    resume = upload_resume_with_drops
    experience = resume.experiences.create!(
      company: "Acme Corp", title: "Engineer", position: 0,
      pending_items: [ { "kind" => "dropped_field", "field" => "location", "reason" => "didn't appear in your original document", "raw_value" => nil } ]
    )

    post resume_pending_items_path(resume),
      params: { pending_item: { scope: "experience", field: "location", position: experience.position, value: "Remote" } }

    assert_response :redirect
    experience.reload
    assert_equal "Remote", experience.location
    assert_equal [], experience.pending_items
    # The resume-level drop from the stub extraction is untouched by an experience-scoped fill.
    assert_includes resume.reload.pending_items.map { |item| item["field"] }, "name"
  end

  test "fills an unparsed date via a plain ISO date value" do
    resume = upload_resume_with_drops
    experience = resume.experiences.create!(
      company: "Acme Corp", title: "Engineer", position: 0,
      pending_items: [ { "kind" => "unparsed_date", "field" => "starts_on", "reason" => "not recognized as a date", "raw_value" => "Summer 2020" } ]
    )

    post resume_pending_items_path(resume),
      params: { pending_item: { scope: "experience", field: "starts_on", position: experience.position, value: "2020-06-01" } }

    assert_response :redirect
    experience.reload
    assert_equal Date.new(2020, 6, 1), experience.starts_on
    assert_equal [], experience.pending_items
  end

  test "an unparseable date value re-renders with an error instead of raising" do
    resume = upload_resume_with_drops
    experience = resume.experiences.create!(
      company: "Acme Corp", title: "Engineer", position: 0,
      pending_items: [ { "kind" => "unparsed_date", "field" => "starts_on", "reason" => "not recognized as a date", "raw_value" => "Summer 2020" } ]
    )

    post resume_pending_items_path(resume),
      params: { pending_item: { scope: "experience", field: "starts_on", position: experience.position, value: "not-a-date" } }

    assert_response :unprocessable_entity
    experience.reload
    assert_nil experience.starts_on
    assert_equal 1, experience.pending_items.size
  end

  test "appends a skill without disturbing existing skills" do
    resume = upload_resume_with_drops
    resume.update!(skills: [ "Ruby" ], pending_items: resume.pending_items + [
      { "kind" => "dropped_field", "field" => "skill", "reason" => "a skill didn't appear in your original document", "raw_value" => nil }
    ])

    post resume_pending_items_path(resume), params: { pending_item: { scope: "resume", field: "skill", value: "Kubernetes" } }

    assert_response :redirect
    assert_equal [ "Ruby", "Kubernetes" ], resume.reload.skills
    assert_not_includes resume.pending_items.map { |item| item["field"] }, "skill"
  end

  test "appends a bullet to the right experience without disturbing existing bullets" do
    resume = upload_resume_with_drops
    experience = resume.experiences.create!(
      company: "Acme Corp", title: "Engineer", position: 0, bullets: [ "Led migration" ],
      pending_items: [ { "kind" => "dropped_field", "field" => "bullet", "reason" => "a bullet didn't closely match your original document", "raw_value" => nil } ]
    )

    post resume_pending_items_path(resume),
      params: { pending_item: { scope: "experience", field: "bullet", position: experience.position, value: "Mentored two engineers" } }

    assert_response :redirect
    experience.reload
    assert_equal [ "Led migration", "Mentored two engineers" ], experience.bullets
    assert_equal [], experience.pending_items
  end

  test "a whole dropped experience entry cannot be filled in, even by a crafted request" do
    resume = upload_resume_with_drops
    resume.update!(pending_items: resume.pending_items + [
      { "kind" => "dropped_field", "field" => "experience", "reason" => "an experience entry couldn't be verified", "raw_value" => nil }
    ])

    post resume_pending_items_path(resume), params: { pending_item: { scope: "resume", field: "experience", value: "Anything" } }

    assert_response :not_found
    assert_includes resume.reload.pending_items.map { |item| item["field"] }, "experience"
  end

  test "a field with no matching pending item is rejected" do
    resume = upload_resume_with_drops

    post resume_pending_items_path(resume), params: { pending_item: { scope: "resume", field: "phone", value: "555-000-0000" } }

    assert_response :not_found
    assert_nil resume.reload.phone
  end

  # Both routes go through find_owned_resume!, whose RecordNotFound is
  # deliberately unrescued (ApplicationController) so an owner mismatch falls
  # through to Rails' same default 404 a nonexistent id gets -- see ADR-0029.
  # Only status is compared, not the full body: test env renders the debug
  # error page for an uncaught RecordNotFound, which embeds request-specific
  # content (the id itself, object ids) that differs by construction between
  # the two cases here. That's a test-environment artifact of
  # consider_all_requests_local, not a leak -- production's actual 404
  # response is static and identical either way, same as every other
  # RecordNotFound-based check in this codebase (e.g.
  # JobDescriptionComparisonsTest's owner-mismatch test asserts status only).
  test "filling a pending item on a resume from a different session 404s the same as a resume that doesn't exist" do
    resume = upload_resume_with_drops
    fake_id = resume.id + 1_000_000

    reset!
    sign_in_as(users(:alex))
    post resume_pending_items_path(resume_id: fake_id), params: { pending_item: { scope: "resume", field: "name", value: "Someone Else" } }
    assert_response :not_found

    reset!
    sign_in_as(users(:alex))
    post resume_pending_items_path(resume_id: resume.id), params: { pending_item: { scope: "resume", field: "name", value: "Someone Else" } }
    assert_response :not_found
  end

  private

  # Fixture content deliberately omits "Stub Candidate"/"stub@example.com" --
  # LlmCallGuard's test-env StubChat always returns those as name/email
  # regardless of file content, so a fixture that doesn't literally contain
  # them fails Resume::Extractors::Llm's verbatim-match check and produces
  # real dropped_field pending items for name and email, the same way a real
  # fabrication would. See LlmCallGuard::StubChat#stub_content.
  def upload_resume_with_drops
    path = write_fixture({ note: "irrelevant filler text" }.to_json)
    post resumes_path, params: { file: Rack::Test::UploadedFile.new(path, "application/json") }
    Resume.last
  ensure
    File.delete(path) if path && File.exist?(path)
  end

  def write_fixture(content)
    path = Rails.root.join("tmp/pending_item_fills_test_#{SecureRandom.hex(4)}.json").to_s
    File.write(path, content)
    path
  end
end
