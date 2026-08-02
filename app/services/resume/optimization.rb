# Produces a Resume::Pdf-renderable view of a Resume with each experience's
# bullets rewritten (via BulletRewriter) against a specific job description,
# without persisting anything or touching the original Resume/Experience
# records. Result/Experience deliberately mirror the exact attribute names
# Resume::Pdf reads off a real Resume/Experience, so Resume::Pdf.call(resume:
# Resume::Optimization.call(...)) needs no changes to Resume::Pdf itself.
class Resume::Optimization
  Result = Data.define(:name, :email, :phone, :summary, :skills, :experiences, :educations)
  Experience = Data.define(:company, :title, :location, :starts_on, :ends_on, :bullets)

  def self.call(resume:, job_description_text:, chat: LlmCallGuard.chat)
    new(resume: resume, job_description_text: job_description_text, chat: chat).call
  end

  def initialize(resume:, job_description_text:, chat:)
    @resume = resume
    @job_description_text = job_description_text
    @chat = chat
  end

  def call
    Result.new(
      name: resume.name,
      email: resume.email,
      phone: resume.phone,
      summary: resume.summary,
      skills: resume.skills,
      experiences: optimized_experiences,
      educations: resume.educations
    )
  end

  private

  attr_reader :resume, :job_description_text, :chat

  # This is the pipeline's only LLM fan-out: one BulletRewriter request per
  # experience that actually has bullets. That count is known here, before the
  # first billable request, so the daily cap is checked against the whole flow
  # rather than discovered partway through it (issue #75). Without this, a
  # resume that cannot fit in today's remaining budget still pays for every
  # rewrite up to the one that trips the cap, and delivers nothing.
  def optimized_experiences
    LlmCallGuard.ensure_headroom!(rewrite_request_count)

    resume.experiences.map do |experience|
      Experience.new(
        company: experience.company,
        title: experience.title,
        location: experience.location,
        starts_on: experience.starts_on,
        ends_on: experience.ends_on,
        bullets: BulletRewriter.call(
          bullets: experience.bullets,
          job_description_text: job_description_text,
          chat: chat
        )
      )
    end
  end

  # BulletRewriter returns early for an experience with no bullets, before it
  # issues anything, so those cost nothing and must not count against the cap.
  def rewrite_request_count
    resume.experiences.count { |experience| experience.bullets.present? }
  end
end
