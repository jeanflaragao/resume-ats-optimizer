// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import { Turbo } from "@hotwired/turbo-rails"
import "controllers"

// Turbo's progress bar has two separate style-src problems (issue #60). The
// constructor sets one deterministic inline style (width: 10%) unconditionally,
// regardless of visibility -- that one is allowlisted by exact hash in
// config/initializers/content_security_policy.rb, since a nonce can't cover an
// inline style-attribute mutation. But once the bar becomes visible (show(),
// gated by progressBarDelay, default 500ms) it trickles its width via
// Math.random() on every tick -- a genuinely different value each time, which no
// hash or nonce can ever cover. This app's slow steps (LLM-backed bullet
// rewriting, PDF generation) are exactly the kind of request that would cross a
// 500ms delay in production, so the bar is disabled from ever becoming visible
// (2147483647 = max signed 32-bit delay setTimeout accepts; Infinity is not a
// finite number and browsers clamp/coerce it unpredictably) rather than
// widening style-src for a cosmetic-only, unhashable animation. The app's own
// "Preparing your download"/"Generating..." status text already covers slow-
// request feedback.
Turbo.config.drive.progressBarDelay = 2147483647
