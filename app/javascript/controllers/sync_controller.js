import { Controller } from "@hotwired/stimulus"

// Keeps a hidden field in a second <form> mirroring a visible field in the
// first -- needed because Rails' per-form CSRF tokens (config.load_defaults
// 8.0) bind a form's authenticity_token to its own declared action, so a
// single shared form with a formaction-overridden submit button fails CSRF
// verification on a real (non-Turbo) browser POST. See issue #47/CLAUDE.md.
export default class extends Controller {
  static targets = ["source", "target"]

  connect() {
    this.sync()
  }

  sync() {
    this.targetTarget.value = this.sourceTarget.value
  }
}
