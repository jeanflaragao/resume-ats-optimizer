# Produces a Resume::Pdf-renderable view of a Resume with each experience's
# bullets rewritten (via BulletRewriter) against a specific job description,
# without persisting anything or touching the original Resume/Experience
# records. Result/Experience deliberately mirror the exact attribute names
# Resume::Pdf reads off a real Resume/Experience, so Resume::Pdf.call(resume:
# Resume::Optimization.call(...)) needs no changes to Resume::Pdf itself.
class Resume::Optimization
  Result = Data.define(:name, :email, :phone, :summary, :skills, :experiences, :educations)
  # bullet_fallbacks is a parallel array (same order/length as bullets, true
  # where BulletRewriter fell back to the original wording) -- purely
  # additive over bullets itself, which stays Array<String> so Resume::Pdf's
  # existing contract with Experience is unchanged. Issue #117: a
  # preview-only signal that Resume::Pdf must never read -- see
  # Resume::OptimizationTest for the test proving that, not just documenting
  # it here.
  Experience = Data.define(:company, :title, :location, :starts_on, :ends_on, :bullets, :bullet_fallbacks)
  # Educations are copied into a value object for the same reason experiences
  # are, rather than passed through as the ActiveRecord relation they used to
  # be (issue #83): Resume::CachedOptimization writes this Result into
  # Rails.cache, and a relation would serialise a database-connected object out
  # of one process and back into a Solid Queue worker in another. Nothing here
  # is loaded lazily, so the Result is now self-contained -- which is what the
  # class comment above already claims of it.
  Education = Data.define(:school, :degree, :field_of_study, :starts_on, :ends_on)

  def self.call(resume:, job_description_text:, chat: LlmCallGuard.chat(subject: resume.user_id.to_s))
    new(resume: resume, job_description_text: job_description_text, chat: chat).call
  end

  # The pipeline's LLM fan-out width: one BulletRewriter request per experience
  # that actually has bullets, since BulletRewriter returns early on an empty
  # list (bullet_rewriter.rb:44) before the request at :46. Public because two
  # callers outside this class need the same number for a different reason --
  # the daily-cap pre-flight below (issue #75) and Resume::CachedOptimization's
  # lock timing, which scales with how long the fan-out will take (issue #83).
  def self.rewrite_request_count(resume)
    resume.experiences.count { |experience| experience.bullets.present? }
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
      educations: copied_educations
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
    LlmCallGuard.ensure_headroom!(rewrite_request_count, subject: resume.user_id.to_s)

    resume.experiences.map do |experience|
      rewrites = BulletRewriter.call(
        bullets: experience.bullets,
        job_description_text: job_description_text,
        chat: chat
      )

      Experience.new(
        company: experience.company,
        title: experience.title,
        location: experience.location,
        starts_on: experience.starts_on,
        ends_on: experience.ends_on,
        bullets: rewrites.map(&:text),
        bullet_fallbacks: rewrites.map(&:fell_back)
      )
    end
  end

  # BulletRewriter returns early for an experience with no bullets, before it
  # issues anything, so those cost nothing and must not count against the cap.
  def rewrite_request_count
    self.class.rewrite_request_count(resume)
  end

  def copied_educations
    resume.educations.map do |education|
      Education.new(
        school: education.school,
        degree: education.degree,
        field_of_study: education.field_of_study,
        starts_on: education.starts_on,
        ends_on: education.ends_on
      )
    end
  end
end
