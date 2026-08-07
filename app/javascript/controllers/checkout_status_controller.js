import { Controller } from "@hotwired/stimulus"

// Fallback for the same race download_status_controller.js already handles
// (issue #72/ADR-0018), for a second async result type: Payments::
// GrantFromEvent's broadcast can fire before this page's ActionCable
// subscription has connected, and broadcasts aren't queued for late
// subscribers. On connect, check once whether the grant already landed by
// the time this page loaded, and swap it in directly if so.
export default class extends Controller {
  static values = { url: String }

  connect() {
    fetch(this.urlValue, { headers: { Accept: "text/html" } }).then((response) => {
      if (!response.ok) return

      response.text().then((html) => {
        if (html.trim()) this.element.outerHTML = html
      })
    })
  }
}
