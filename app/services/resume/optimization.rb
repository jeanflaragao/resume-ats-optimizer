# Produces a Resume::Pdf-renderable view of a Resume with each experience's
# bullets rewritten (via BulletRewriter) against a specific job description,
# without persisting anything or touching the original Resume/Experience
# records. Result/Experience deliberately mirror the exact attribute names
# Resume::Pdf reads off a real Resume/Experience, so Resume::Pdf.call(resume:
# Resume::Optimization.call(...)) needs no changes to Resume::Pdf itself.
class Resume::Optimization
  Result = Data.define(:name, :email, :phone, :summary, :skills, :experiences, :educations)
  Experience = Data.define(:company, :title, :location, :starts_on, :ends_on, :bullets)

  def self.call(resume:, job_description_text:, chat: RubyLLM.chat)
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

  def optimized_experiences
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
end
