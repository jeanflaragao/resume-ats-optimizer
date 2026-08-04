require "test_helper"

class ResumeTest < ActiveSupport::TestCase
  test "skills defaults to an empty array" do
    assert_equal [], Resume.new.skills
  end

  test "skills round-trips as an array" do
    resume = resumes(:one)
    assert_equal [ "Ruby", "Rails", "PostgreSQL" ], resume.skills
  end

  test "experiences are ordered by position" do
    assert_equal [ "Acme Corp", "Globex" ], resumes(:one).experiences.map(&:company)
  end

  test "destroying a resume destroys its experiences and educations" do
    resume = resumes(:one)

    assert_difference "Experience.count", -resume.experiences.count do
      assert_difference "Education.count", -resume.educations.count do
        resume.destroy
      end
    end
  end

  test "purge_stale! deletes a claimed resume last accessed before LAST_ACCESSED_PURGE_AFTER and keeps one accessed since" do
    stale = Resume.create!(owner_token: "token-a", last_accessed_at: Resume::LAST_ACCESSED_PURGE_AFTER.ago - 1.minute)
    recent = Resume.create!(owner_token: "token-b", last_accessed_at: Resume::LAST_ACCESSED_PURGE_AFTER.ago + 1.minute)

    Resume.purge_stale!

    assert_not Resume.exists?(stale.id)
    assert Resume.exists?(recent.id)
  end

  test "purge_stale! deletes a never-claimed resume older than ORPHAN_PURGE_AFTER and keeps one created since" do
    stale_orphan = Resume.create!(owner_token: nil, created_at: Resume::ORPHAN_PURGE_AFTER.ago - 1.minute)
    recent_orphan = Resume.create!(owner_token: nil, created_at: Resume::ORPHAN_PURGE_AFTER.ago + 1.minute)

    Resume.purge_stale!

    assert_not Resume.exists?(stale_orphan.id)
    assert Resume.exists?(recent_orphan.id)
  end

  test "purge_stale! never purges a claimed resume via the orphan tier, even when long unaccessed" do
    # Old enough that ORPHAN_PURGE_AFTER (24h) would catch it if the orphan
    # tier ignored owner_token -- it must not, since this resume is claimed.
    claimed = Resume.create!(
      owner_token: "token-c",
      last_accessed_at: Resume::LAST_ACCESSED_PURGE_AFTER.ago + 1.hour,
      created_at: Resume::ORPHAN_PURGE_AFTER.ago - 1.year
    )

    Resume.purge_stale!

    assert Resume.exists?(claimed.id)
  end

  # Non-vacuity: asserts on Experience/Education/Resume::PdfRequest counts, not
  # just Resume's, so a delete_all-based implementation (which strands children
  # -- see ADR-0026) fails this test instead of passing it vacuously.
  test "purge_stale! removes a stale resume's experiences, educations, and pdf requests, not just the resume" do
    stale = Resume.create!(owner_token: "token-d", last_accessed_at: Resume::LAST_ACCESSED_PURGE_AFTER.ago - 1.minute)
    stale.experiences.create!(company: "Acme", title: "Engineer", position: 1)
    stale.educations.create!(school: "State U", position: 1)
    stale.pdf_requests.create!(download_id: SecureRandom.uuid, text: "irrelevant")

    assert_difference "Resume.count", -1 do
      assert_difference "Experience.count", -1 do
        assert_difference "Education.count", -1 do
          assert_difference "Resume::PdfRequest.count", -1 do
            Resume.purge_stale!
          end
        end
      end
    end
  end
end
