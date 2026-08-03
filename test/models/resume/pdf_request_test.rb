require "test_helper"

class Resume::PdfRequestTest < ActiveSupport::TestCase
  PLAINTEXT = "We need a senior Ruby engineer to lead platform migrations at Contoso.".freeze

  test "the text column holds ciphertext, not the pasted job description" do
    request = create_request(text: PLAINTEXT)

    raw = Resume::PdfRequest.connection.select_value(
      Resume::PdfRequest.sanitize_sql([ "SELECT text FROM resume_pdf_requests WHERE id = ?", request.id ])
    )

    # The whole point of issue #76: whatever a DB dump or a replica sees, it is
    # not the posting. Asserted on a distinctive substring as well as the whole
    # string, so a partial leak fails too.
    assert_not_includes raw, PLAINTEXT
    assert_not_includes raw, "Contoso"
    assert_not_includes raw, "platform migrations"

    # ...and it is genuinely encrypted rather than merely mangled: it still
    # reads back through the model.
    assert_equal PLAINTEXT, request.reload.text
  end

  test "encryption is non-deterministic, so two users pasting the same posting are not linkable" do
    first = create_request(text: PLAINTEXT)
    second = create_request(text: PLAINTEXT)

    ciphertexts = Resume::PdfRequest.connection.select_values(
      Resume::PdfRequest.sanitize_sql([
        "SELECT text FROM resume_pdf_requests WHERE id IN (?, ?)", first.id, second.id
      ])
    )

    assert_not_equal ciphertexts.first, ciphertexts.second
  end

  test "purge_stale! deletes requests older than PURGE_AFTER and keeps recent ones" do
    stale = create_request(created_at: Resume::PdfRequest::PURGE_AFTER.ago - 1.minute)
    recent = create_request(created_at: Resume::PdfRequest::PURGE_AFTER.ago + 1.minute)

    Resume::PdfRequest.purge_stale!

    assert_not Resume::PdfRequest.exists?(stale.id)
    assert Resume::PdfRequest.exists?(recent.id)
  end

  test "destroying a resume takes its pdf requests with it" do
    request = create_request

    assert_difference("Resume::PdfRequest.count", -1) { request.resume.destroy }
  end

  test "download_id is unique, so a replayed enqueue cannot collide with a live download" do
    download_id = SecureRandom.uuid
    create_request(download_id: download_id)

    assert_raises(ActiveRecord::RecordNotUnique) { create_request(download_id: download_id) }
  end

  private

  def create_request(**attributes)
    Resume::PdfRequest.create!(
      { resume: resumes(:one), download_id: SecureRandom.uuid, text: PLAINTEXT }.merge(attributes)
    )
  end
end
