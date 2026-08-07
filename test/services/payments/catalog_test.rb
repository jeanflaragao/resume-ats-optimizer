require "test_helper"

class Payments::CatalogTest < ActiveSupport::TestCase
  test "all returns all three entries" do
    assert_equal %i[five_credits fifteen_credits unlimited_30_days], Payments::Catalog.all.map(&:key)
  end

  test "find returns the entry for a known key, string or symbol" do
    assert_equal :five_credits, Payments::Catalog.find(:five_credits).key
    assert_equal :five_credits, Payments::Catalog.find("five_credits").key
  end

  test "find raises for an unknown key" do
    assert_raises(ArgumentError) { Payments::Catalog.find(:nonexistent) }
  end

  test "price_id_for reads the entry's own env var" do
    with_env("STRIPE_PRICE_ID_5_CREDITS" => "price_abc123") do
      assert_equal "price_abc123", Payments::Catalog.price_id_for(:five_credits)
    end
  end

  test "price_id_for raises when the env var is unset" do
    with_env("STRIPE_PRICE_ID_5_CREDITS" => nil) do
      assert_raises(KeyError) { Payments::Catalog.price_id_for(:five_credits) }
    end
  end

  test "for_price_id reverse-looks-up the matching entry" do
    with_env("STRIPE_PRICE_ID_15_CREDITS" => "price_xyz789") do
      entry = Payments::Catalog.for_price_id("price_xyz789")
      assert_equal :fifteen_credits, entry.key
    end
  end

  test "for_price_id returns nil for a price id that matches no configured entry" do
    assert_nil Payments::Catalog.for_price_id("price_does_not_exist")
  end

  test "credits and unlimited_days are mutually exclusive across every entry" do
    Payments::Catalog.all.each do |entry|
      assert_not (entry.credits.present? && entry.unlimited_days.present?),
        "#{entry.key} sets both credits and unlimited_days"
      assert (entry.credits.present? || entry.unlimited_days.present?),
        "#{entry.key} sets neither credits nor unlimited_days"
    end
  end

  private

  def with_env(vars)
    originals = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
