require "test_helper"

class JobDescription::ExtractorTest < ActiveSupport::TestCase
  # Records what it was asked, and how often, so a test can assert that a call
  # was *not* issued — the LLM budget is the thing being protected.
  class FakeChat
    attr_reader :schema, :prompt, :ask_count

    def initialize(content_to_return = nil)
      @content_to_return = content_to_return
      @ask_count = 0
    end

    def with_schema(schema)
      @schema = schema
      self
    end

    def ask(prompt, with: nil)
      @ask_count += 1
      @prompt = prompt
      Struct.new(:content).new(@content_to_return)
    end
  end

  FULL_RESPONSE = {
    "title" => "Senior Ruby Engineer",
    "seniority_level" => "Senior",
    "years_experience_min" => 5,
    "required_skills" => [ "Ruby", "Rails" ],
    "preferred_skills" => [ "Postgres" ],
    "keywords" => [ "AWS" ],
    "responsibilities" => [ "Own the billing service" ],
    "education_requirements" => [ "BSc Computer Science or equivalent experience" ],
    "soft_skills" => [ "Mentoring" ]
  }.freeze

  test "sends the job description text and schema to RubyLLM and returns the parsed content" do
    fake_chat = FakeChat.new(FULL_RESPONSE)

    result = JobDescription::Extractor.call(text: "We need a Senior Ruby Engineer...", chat: fake_chat)

    assert_equal FULL_RESPONSE, result
    assert_equal JobDescription::ExtractionSchema, fake_chat.schema
    assert_includes fake_chat.prompt, "Extract"
    assert_includes fake_chat.prompt, "We need a Senior Ruby Engineer..."
  end

  # Blank input has nothing to extract, so issuing the request would spend real
  # money and a slot against LlmCallGuard's daily cap to be told so.
  test "a blank job description returns the empty result without issuing a request" do
    [ "", "   \n\t ", nil ].each do |blank|
      fake_chat = FakeChat.new(FULL_RESPONSE)

      result = JobDescription::Extractor.call(text: blank, chat: fake_chat)

      assert_equal JobDescription::Extractor::EMPTY_RESULT, result
      assert_equal 0, fake_chat.ask_count, "expected no LLM request for #{blank.inspect}"
    end
  end

  test "a response missing fields is filled in rather than passed through" do
    fake_chat = FakeChat.new({ "required_skills" => [ "Ruby" ] })

    result = JobDescription::Extractor.call(text: "Ruby role", chat: fake_chat)

    assert_equal JobDescription::Extractor::EMPTY_RESULT.keys.sort, result.keys.sort
    assert_equal [ "Ruby" ], result["required_skills"]
    assert_equal [], result["preferred_skills"]
    assert_equal [], result["responsibilities"]
    assert_equal [], result["soft_skills"]
    assert_nil result["title"]
    assert_nil result["years_experience_min"]
  end

  # A null is what the schema asks for when a posting states no minimum, so it
  # has to land on the same value an omitted key does.
  test "a response with explicit nulls falls back to the same defaults" do
    fake_chat = FakeChat.new(FULL_RESPONSE.merge("keywords" => nil, "years_experience_min" => nil))

    result = JobDescription::Extractor.call(text: "Ruby role", chat: fake_chat)

    assert_equal [], result["keywords"]
    assert_nil result["years_experience_min"]
  end

  test "keys outside the schema are dropped" do
    fake_chat = FakeChat.new(FULL_RESPONSE.merge("salary_band" => "£90k"))

    result = JobDescription::Extractor.call(text: "Ruby role", chat: fake_chat)

    assert_equal FULL_RESPONSE, result
  end

  # The three keys Comparison reads (app/services/comparison.rb) — pinned here
  # because renaming one silently zeroes every match score rather than failing.
  test "the keys Comparison matches on are present and unrenamed" do
    fake_chat = FakeChat.new(FULL_RESPONSE)

    result = JobDescription::Extractor.call(text: "Ruby role", chat: fake_chat)
    comparison = Comparison.call(resume: resumes(:one), requirements: result)

    assert_includes comparison.matched_required_skills + comparison.missing_required_skills, "Ruby"
    assert_includes comparison.matched_preferred_skills + comparison.missing_preferred_skills, "Postgres"
    assert_includes comparison.matched_keywords + comparison.missing_keywords, "AWS"
  end

  test "the schema declares every extracted field, with an optional integer minimum" do
    schema = JobDescription::ExtractionSchema.new.to_json_schema[:schema]

    assert_equal JobDescription::Extractor::EMPTY_RESULT.keys.sort, schema[:properties].keys.map(&:to_s).sort
    assert_equal "integer", schema[:properties][:years_experience_min][:type]
    refute_includes schema[:required], :years_experience_min
    refute_includes schema[:required], :title
  end

  # The provider's structured-output validation rejects a `minimum` keyword on
  # an integer property with HTTP 400 ("property 'minimum' is not supported"),
  # which made every real "Check match" request fail. Not something a
  # FakeChat-based test can catch on its own, since FakeChat never validates
  # the schema the way the real API does — so this pins the one property of
  # the generated schema that mattered: no `minimum` key, at all.
  test "the schema does not constrain years_experience_min with a minimum, which the provider rejects" do
    schema = JobDescription::ExtractionSchema.new.to_json_schema[:schema]

    refute schema[:properties][:years_experience_min].key?(:minimum)
  end
end
