# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header
#
# Scoped to what this app actually loads (issue #60): everything is same-origin —
# no CDN scripts, no third-party fonts, no inline scripts or styles anywhere in
# app/views/ — so the policy below does not need :https-scheme or 'unsafe-inline'
# allowances the Rails scaffold's commented-out example carries.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :self
    # Turbo's progress bar (turbo-rails 2.0.23) sets `element.style.width = "10%"`
    # unconditionally in its constructor -- at Turbo's own module-load time, not
    # gated by progressBarDelay/visibility, and with no public API to prevent it.
    # A nonce cannot cover this (nonces only attach to <style>/<script> elements,
    # never to inline style-attribute mutations), so this is 'unsafe-hashes' plus
    # the exact SHA-256 of that one literal, byte-identical value Turbo always
    # sets -- not a blanket 'unsafe-inline' allowance. If this value ever changes
    # in a turbo-rails upgrade, the hash stops matching and the violation reappears
    # loudly (report-only or the system test) rather than silently. This hash covers
    # only the constructor's one-time value -- it does NOT make the bar safe to
    # re-enable; see docs/adr/0027-disable-turbo-progress-bar-for-csp.md and
    # app/javascript/application.js's progressBarDelay line, which this depends on.
    policy.style_src :self, :unsafe_hashes, "sha256-WAyOw4V+FqDc35lQPyRADLBWbuNK8ahvYEaQIYF1+Ps="
    policy.img_src     :self, :data
    policy.object_src  :none
    policy.connect_src :self
  end

  # A fresh nonce per response, not the scaffold's session-id-based example: reusing
  # the session id as the nonce means every response in a session shares the same
  # nonce, which is weaker than the per-response unpredictability a nonce is meant to
  # provide. importmap-rails (javascript_importmap_tags) already calls this generator
  # and stamps the result on the importmap script, its inline bootstrap module script,
  # and any modulepreload links -- no view changes needed. Only script-src needs
  # nonce'ing: there are no inline <style> elements anywhere to justify style-src here.
  config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]

  # Report-only pass (issue #60) confirmed zero violations across the full
  # upload -> check match -> preview -> download flow, including real, multi-
  # second LLM-backed requests and the live ActionCable/Turbo Stream download
  # broadcast -- see the PR body for the full report. Enforcing now.
end
