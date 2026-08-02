require "simplecov"
SimpleCov.start "rails" do
  # Measured baseline as of the coverage-tracking PR: 95.42% (334/350 lines).
  # Set a few points below that rather than at/above it, so the threshold
  # has room to absorb minor fluctuations without blocking every PR, while
  # still catching a real regression.
  minimum_coverage 90
end

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

Dir[Rails.root.join("test/support/**/*.rb")].each { |file| require file }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include RecordingLlm

    # Add more helper methods to be used by all tests here...
  end
end
