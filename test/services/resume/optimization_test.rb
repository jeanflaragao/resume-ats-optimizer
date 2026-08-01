require "test_helper"
require "pdf/reader"

class Resume::OptimizationTest < ActiveSupport::TestCase
  # Bullet rewriting happens once per experience, so a resume with multiple
  # experiences needs a different LLM response per call -- responses are
  # consumed off the front of the queue in call order.
  FakeChat = Struct.new(:responses) do
    def prompts
      @prompts ||= []
    end

    def with_schema(schema)
      @schema = schema
      self
    end

    def ask(prompt)
      prompts << prompt
      Struct.new(:content).new(responses.shift)
    end
  end

  test "rewritten bullets appear in the rendered PDF, not the originals" do
    resume = resumes(:one)
    fake_chat = FakeChat.new([
      { "bullets" => [ "Led the migration to microservices", "Mentored the three junior engineers" ] }
    ])

    result = Resume::Optimization.call(resume: resume, job_description_text: "Anything.", chat: fake_chat)
    text = extract_text(Resume::Pdf.call(resume: result))

    assert_includes text, "Led the migration to microservices"
    assert_includes text, "Mentored the three junior engineers"
    refute_includes text, "Led migration to microservices"
    refute_includes text, "Mentored three junior engineers"
  end

  test "does not mutate the original Resume/Experience records" do
    resume = resumes(:one)
    original_bullets = resume.experiences.map(&:bullets)
    fake_chat = FakeChat.new([
      { "bullets" => [ "Led the migration to microservices", "Mentored the three junior engineers" ] }
    ])

    Resume::Optimization.call(resume: resume, job_description_text: "Anything.", chat: fake_chat)

    resume.reload
    assert_equal original_bullets, resume.experiences.map(&:bullets)
  end

  test "passes name/email/phone/summary/skills/educations through unchanged" do
    resume = resumes(:one)
    fake_chat = FakeChat.new([
      { "bullets" => [ "Led the migration to microservices", "Mentored the three junior engineers" ] }
    ])

    result = Resume::Optimization.call(resume: resume, job_description_text: "Anything.", chat: fake_chat)

    assert_equal resume.name, result.name
    assert_equal resume.email, result.email
    assert_equal resume.phone, result.phone
    assert_equal resume.summary, result.summary
    assert_equal resume.skills, result.skills
    assert_equal resume.educations.to_a, result.educations.to_a

    experience = result.experiences.first
    assert_instance_of Resume::Optimization::Experience, experience
    assert_equal resume.experiences.first.company, experience.company
    assert_equal resume.experiences.first.title, experience.title
    assert_equal resume.experiences.first.location, experience.location
  end

  test "does not call the LLM for an experience with no bullets" do
    resume = Resume.new(name: "Alex Doe")
    resume.experiences.build(company: "Acme", title: "Engineer", bullets: [], position: 1)
    fake_chat = FakeChat.new([])

    result = Resume::Optimization.call(resume: resume, job_description_text: "Anything.", chat: fake_chat)

    assert_equal [], result.experiences.first.bullets
    assert_empty fake_chat.prompts
  end

  test "falls back to the original bullet when a rewrite fails its fidelity check" do
    resume = Resume.new(name: "Alex Doe")
    resume.experiences.build(company: "Acme", title: "Engineer", bullets: [ "Built REST APIs" ], position: 1)
    fake_chat = FakeChat.new([
      { "bullets" => [ "Built REST APIs using Kubernetes and reduced latency by 40%" ] }
    ])

    result, log_output = with_captured_log do
      Resume::Optimization.call(resume: resume, job_description_text: "Anything.", chat: fake_chat)
    end

    assert_equal [ "Built REST APIs" ], result.experiences.first.bullets
    assert_includes log_output, "bullet 1"
  end

  private

  def extract_text(bytes)
    PDF::Reader.new(StringIO.new(bytes)).pages.map(&:text).join("\n")
  end

  def with_captured_log
    original_logger = Rails.logger
    io = StringIO.new
    Rails.logger = Logger.new(io)
    result = yield
    [ result, io.string ]
  ensure
    Rails.logger = original_logger
  end
end
