// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import { Turbo } from "@hotwired/turbo-rails"
import "controllers"

// Disables Turbo's progress bar app-wide, permanently -- this is a load-bearing
// line, not a cosmetic tweak. See docs/adr/0027-disable-turbo-progress-bar-for-csp.md
// for the full reasoning (issue #60): the bar's constructor sets one deterministic
// inline style (allowlisted by hash in config/initializers/content_security_policy.rb),
// but its trickle animation sets a genuinely different, un-hashable inline style on
// every tick once visible. Removing this line does not just restore a loading
// spinner -- it reintroduces CSP violations on every request slower than 500ms,
// including under the enforcing policy. Any new slow Turbo-driven interaction needs
// its own status text (see resumes/show.html.erb, downloads/create.html.erb); none
// will get a progress bar automatically.
// 2147483647 = max signed 32-bit delay setTimeout accepts; Infinity is not a finite
// number and browsers clamp/coerce it unpredictably.
Turbo.config.drive.progressBarDelay = 2147483647
