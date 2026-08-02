# Measures how long Resume::Optimization actually takes, so
# Resume::CachedOptimization's lock timings are sized from data rather than
# guessed (issue #83, ADR-0021).
#
# Re-run this whenever config/initializers/ruby_llm.rb's default_model changes:
# PIPELINE_PER_EXPERIENCE and the safety factors were measured against one
# specific model, and nothing else will tell you they have gone stale.
#
#   docker compose run --rm web bin/rails runner script/measure_optimization_latency.rb
#
# Needs ENABLE_REAL_LLM_CALLS=true and a real ANTHROPIC_API_KEY -- it aborts
# rather than measure stub mode, which would be meaningless. Costs 3 + 5 = 8
# real provider requests, so MAX_LLM_CALLS_PER_DAY must have that much headroom.
#
# Runs the pipeline on a 3-experience and a 5-experience resume against one
# realistic posting, and reports each total plus the per-request latency of
# every BulletRewriter call. The per-request list is the important part: it
# shows whether the fan-out is still sequential, and pooling those samples is a
# better per-experience estimate than the two-point slope (T5-T3)/2, which
# differences two noisy totals and discards most of the data.

JOB_DESCRIPTION = <<~POSTING.freeze
  Senior Ruby Engineer, Platform Infrastructure

  About the role

  We are looking for a Senior Ruby Engineer to join the Platform Infrastructure
  group, a team of nine engineers responsible for the services every product
  team at the company builds on top of. You will own the systems that handle
  billing, identity, and asynchronous work across a Rails monolith that serves
  roughly forty thousand requests per minute at peak, plus a small number of
  extracted services that sit alongside it. This is a hands-on engineering role
  with a strong architectural component: you will be expected to write code
  most days, and also to write the design documents that decide what the rest
  of the group builds next quarter.

  The platform group is in the middle of a multi-year migration away from a
  single Postgres primary and toward horizontally partitioned data stores. We
  have finished the read-path work and are beginning the harder write-path
  migration. We need someone who has done this kind of incremental, no-downtime
  migration before and who is comfortable operating in a codebase where the old
  and new paths coexist for months at a time.

  What you will do

  Design, build, and operate backend services in Ruby and Rails, with an
  emphasis on the data layer: query performance, connection management,
  partitioning strategy, and the operational tooling around all three. Lead the
  incremental migration of write paths onto partitioned tables, including
  backfills, dual-write windows, and the verification jobs that prove the two
  copies agree before a cutover. Improve the reliability of our background job
  infrastructure, currently a mix of Sidekiq and a homegrown scheduler that we
  intend to consolidate. Own the observability story for the services you build:
  meaningful metrics, structured logs, useful traces, and alerts that fire on
  user-visible symptoms rather than on internal noise. Participate in a shared
  on-call rotation, roughly one week in six, with a strong culture of blameless
  incident review and a hard rule that repeat incidents get engineering time
  rather than a runbook entry. Mentor engineers earlier in their careers through
  design review, pairing, and thorough written code review. Partner with product
  engineering teams to make the platform easier to build on, which in practice
  means a lot of listening to what is currently painful.

  What we are looking for

  Substantial professional experience writing Ruby in production, including
  several years working on a large Rails application rather than only on
  greenfield services. Deep familiarity with relational databases, especially
  Postgres: you should be comfortable reading a query plan, reasoning about lock
  contention, and choosing an index without guessing. Experience with
  asynchronous processing at scale, including the failure modes: duplicate
  execution, poison messages, retry storms, and queues that back up faster than
  they drain. A track record of migrations performed without downtime on systems
  that could not be taken offline. Strong written communication. Our team is
  distributed across six time zones, and design documents and code review
  comments are the primary way decisions get made and recorded. Comfort with
  ambiguity and with owning a problem end to end, from the first investigation
  through to the alerting that tells you it stayed fixed.

  Nice to have

  Experience with Kubernetes and with deploying Rails applications onto it.
  Familiarity with Terraform or a similar infrastructure-as-code tool. Exposure
  to event-driven architectures and to the tradeoffs of eventual consistency in
  a product surface users interact with directly. Experience with payments,
  billing, or subscription systems and their reconciliation requirements.
  Contributions to open source Ruby projects. Prior experience as a technical
  lead or staff engineer, or interest in growing in that direction.

  How we work

  We deploy continuously, typically forty to sixty times a day, behind feature
  flags. We write tests, and we care more about whether a test would catch a
  real regression than about a coverage number. Code review is mandatory and is
  expected to be substantive. We do not have a separate QA organisation, so
  engineers own the quality of what they ship. Planning happens quarterly and
  loosely; we protect large blocks of uninterrupted engineering time and keep
  recurring meetings to a minimum. On-call is compensated and is genuinely
  quiet most weeks, which is a deliberate result of the reliability work
  described above rather than luck.

  Compensation and benefits

  Competitive base salary benchmarked against the top quartile for the role and
  location, meaningful equity, comprehensive health coverage, a generous
  learning and conference budget, and a home office stipend. We are remote-first
  within a set of supported countries, with two company gatherings a year.

  Our interview process is four conversations: an introductory call, a practical
  coding session in a codebase resembling ours, a systems design discussion
  anchored on a real problem our team has solved, and a values conversation. We
  give a decision within a week of the final conversation, and we give real
  feedback either way.
POSTING

EXPERIENCES = [
  {
    company: "Ferndale Logistics",
    title: "Staff Backend Engineer",
    bullets: [
      "Partitioned the shipments table across sixteen Postgres shards using a dual-write window and a nightly verification job",
      "Cut median checkout latency from 840ms to 210ms by replacing a correlated subquery with a materialised summary table",
      "Led the on-call rotation redesign that reduced repeat incidents from eleven per quarter to two"
    ]
  },
  {
    company: "Kestrel Health",
    title: "Senior Ruby Engineer",
    bullets: [
      "Rebuilt the claims reconciliation pipeline in Rails, processing 2.4 million records nightly without manual intervention",
      "Introduced structured logging and per-endpoint latency alerting across fourteen services",
      "Mentored four engineers through their first production database migrations"
    ]
  },
  {
    company: "Trellis Commerce",
    title: "Backend Engineer",
    bullets: [
      "Migrated background processing from a homegrown scheduler onto Sidekiq with idempotent job wrappers",
      "Reduced Postgres connection exhaustion incidents to zero by introducing PgBouncer and a connection budget per service",
      "Wrote the design document that consolidated three overlapping billing services into one"
    ]
  },
  {
    company: "Halcyon Media",
    title: "Backend Engineer",
    bullets: [
      "Built the subscription proration engine handling upgrades, downgrades, and mid-cycle plan changes",
      "Automated the quarterly revenue reconciliation that had previously taken two finance analysts a week"
    ]
  },
  {
    company: "Underhill Software",
    title: "Software Engineer",
    bullets: [
      "Shipped the customer-facing API used by nine integration partners, including its versioning policy",
      "Replaced nightly CSV exports with an incremental webhook delivery system with at-least-once semantics"
    ]
  }
].freeze

# Wraps whatever LlmCallGuard hands back, so counting and the daily cap still
# happen exactly as in production; this only times each request.
class TimingChat
  attr_reader :timings

  def initialize(inner, timings = [])
    @inner = inner
    @timings = timings
  end

  def with_schema(schema)
    self.class.new(@inner.with_schema(schema), @timings)
  end

  def ask(prompt = nil, **options)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = @inner.ask(prompt, **options)
    @timings << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    result
  end
end

def resume_with(count)
  resume = Resume.new(name: "Dana Okonkwo", email: "dana.okonkwo@example.com", summary: "Backend engineer.")
  EXPERIENCES.first(count).each_with_index do |attributes, index|
    resume.experiences.build(**attributes, position: index)
  end
  resume
end

def measure(count)
  chat = TimingChat.new(LlmCallGuard.chat)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  Resume::Optimization.call(resume: resume_with(count), job_description_text: JOB_DESCRIPTION, chat: chat)
  total = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

  puts format("N=%d  total=%.2fs  requests=%d  per-request=[%s]",
    count, total, chat.timings.size, chat.timings.map { |t| format("%.2f", t) }.join(", "))
  total
end

abort("ENABLE_REAL_LLM_CALLS is not true — this measurement is meaningless in stub mode") unless LlmCallGuard.enabled?

puts "model=#{RubyLLM.config.default_model}  cap=#{LlmCallGuard.max_calls_per_day}"
puts "job description: #{JOB_DESCRIPTION.split.size} words, #{JOB_DESCRIPTION.length} chars"
puts

t3 = measure(3)
t5 = measure(5)

per_experience = (t5 - t3) / 2.0
fixed_overhead = t3 - (3 * per_experience)

puts
puts format("T3=%.2fs  T5=%.2fs", t3, t5)
puts format("per_experience=(T5-T3)/2=%.2fs  fixed_overhead=T3-3*per_experience=%.2fs", per_experience, fixed_overhead)
puts format("model predicts N=9 at %.2fs", fixed_overhead + (9 * per_experience))
