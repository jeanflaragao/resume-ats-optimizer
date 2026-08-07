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

  test "purge_stale! deletes a resume last accessed before LAST_ACCESSED_PURGE_AFTER and keeps one accessed since" do
    stale = Resume.create!(user: users(:jordan), last_accessed_at: Resume::LAST_ACCESSED_PURGE_AFTER.ago - 1.minute)
    recent = Resume.create!(user: users(:alex), last_accessed_at: Resume::LAST_ACCESSED_PURGE_AFTER.ago + 1.minute)

    Resume.purge_stale!

    assert_not Resume.exists?(stale.id)
    assert Resume.exists?(recent.id)
  end

  # Non-vacuity: asserts on Experience/Education/Resume::PdfRequest counts, not
  # just Resume's, so a delete_all-based implementation (which strands children
  # -- see ADR-0034) fails this test instead of passing it vacuously.
  test "purge_stale! removes a stale resume's experiences, educations, and pdf requests, not just the resume" do
    stale = Resume.create!(user: users(:jordan), last_accessed_at: Resume::LAST_ACCESSED_PURGE_AFTER.ago - 1.minute)
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

  # Issue #121/ADR-0034: credits (issue #122) are a permanent liability, never
  # deleted alongside a purged account's resumes. Usage::Counter is the
  # closest analog available today -- #122's actual Credit model doesn't
  # exist yet -- so this asserts the boundary Resume.purge_stale! must never
  # cross using what's buildable now, standing in for the real balance check
  # once #122 lands.
  #
  # Issue #122: now that users.credits/unlimited_until exist, this test
  # asserts against the real balance too, not just its Usage::Counter analog
  # -- exactly what the comment above already anticipated revisiting.
  #
  # Non-vacuity: the guarantee is structural (Resume.purge_stale!'s where
  # clause only ever selects from resumes, and there is no cascade from a
  # resumes row to its owning users row -- the foreign key points the other
  # direction), so there is no "unfixed" version of *this* code to run the
  # test against. Proven instead by temporarily pointing the purge at a scope
  # that also destroyed the owner (`stale.each { |r| r.user.destroy! }`
  # spliced into a local copy of purge_stale!) and confirming this test goes
  # red, then reverting -- recorded in the PR body.
  test "purge_stale! does not delete the resume's owner, touch their usage counters, or touch their credit balance" do
    user = users(:jordan)
    user.update!(credits: 5, unlimited_until: 10.days.from_now)
    Usage::Counter.consume!(subject_token: user.id.to_s, action_type: "resume_extraction")
    Resume.create!(user: user, last_accessed_at: Resume::LAST_ACCESSED_PURGE_AFTER.ago - 1.minute)

    Resume.purge_stale!

    assert User.exists?(user.id)
    assert_equal 1, Usage::Counter.find_by(subject_token: user.id.to_s, action_type: "resume_extraction").count
    user.reload
    assert_equal 5, user.credits
    assert_in_delta 10.days.from_now, user.unlimited_until, 1.second
  end
end
