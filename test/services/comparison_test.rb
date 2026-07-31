require "test_helper"

class ComparisonTest < ActiveSupport::TestCase
  test "matches required skills present in the resume's skills or bullets" do
    resume = build_resume(skills: [ "Ruby", "PostgreSQL" ], bullets: [ "Deployed services on AWS" ])
    requirements = { "required_skills" => [ "Ruby", "AWS", "Kubernetes" ] }

    result = Comparison.call(resume: resume, requirements: requirements)

    assert_equal [ "Ruby", "AWS" ], result.matched_required_skills
    assert_equal [ "Kubernetes" ], result.missing_required_skills
  end

  test "matches preferred skills and keywords independently" do
    resume = build_resume(skills: [ "Go" ], summary: "Backend engineer focused on scalability.")
    requirements = {
      "preferred_skills" => [ "Go", "Rust" ],
      "keywords" => [ "scalability", "leadership" ]
    }

    result = Comparison.call(resume: resume, requirements: requirements)

    assert_equal [ "Go" ], result.matched_preferred_skills
    assert_equal [ "Rust" ], result.missing_preferred_skills
    assert_equal [ "scalability" ], result.matched_keywords
    assert_equal [ "leadership" ], result.missing_keywords
  end

  test "does not match a short term as a substring of a longer word" do
    resume = build_resume(skills: [ "Google Cloud Platform" ])
    requirements = { "required_skills" => [ "Go" ] }

    result = Comparison.call(resume: resume, requirements: requirements)

    assert_equal [], result.matched_required_skills
    assert_equal [ "Go" ], result.missing_required_skills
  end

  test "matching is case-insensitive" do
    resume = build_resume(skills: [ "ruby" ])
    requirements = { "required_skills" => [ "Ruby" ] }

    result = Comparison.call(resume: resume, requirements: requirements)

    assert_equal [ "Ruby" ], result.matched_required_skills
  end

  test "ignores blank requirement terms and missing requirement keys" do
    resume = build_resume(skills: [ "Ruby" ])

    result = Comparison.call(resume: resume, requirements: {})

    assert_equal [], result.matched_required_skills
    assert_equal [], result.missing_required_skills
    assert_equal [], result.matched_preferred_skills
    assert_equal [], result.missing_preferred_skills
  end

  private

  def build_resume(skills: [], summary: nil, bullets: [])
    resume = Resume.new(skills: skills, summary: summary)
    resume.experiences.build(company: "Acme", title: "Engineer", bullets: bullets) if bullets.any?
    resume
  end
end
