require "test_helper"

class CacheConfigTest < ActiveSupport::TestCase
  test "production cache config declares the cache database" do
    config = Rails.application.config_for(:cache, env: "production")

    assert_equal "cache", config[:database].to_s
  end
end
