require "ruby_llm/schema" # not auto-required by ruby_llm; needed for RubyLLM::Schema subclasses

RubyLLM.configure do |config|
  config.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]
  config.default_model = "claude-sonnet-4-5"
end
