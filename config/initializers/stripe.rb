# Deferred to to_prepare, not called bare at the top level, purely for
# ordering: config/initializers/payments_config_guard.rb sorts before this
# file alphabetically, so that check has already had the chance to abort boot
# by the time this block runs -- Stripe is never configured with a key a
# production deploy would have already refused to boot without. Same
# reasoning config/initializers/ruby_llm.rb documents relative to
# llm_call_guard.rb.
Rails.application.config.to_prepare do
  Stripe.api_key = ENV["STRIPE_SECRET_KEY"]
end
