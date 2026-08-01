import { Controller } from "@hotwired/stimulus"

// Fallback for a real race (confirmed via manual testing, not hypothetical):
// Resume::OptimizedPdfJob can finish and broadcast its Turbo Stream update
// before this page's ActionCable subscription has connected -- broadcasts
// aren't queued for late subscribers, so the update is simply lost, leaving
// "Generating..." stuck forever even though the download is actually ready.
// On connect, check once whether the result was already ready by the time
// this page loaded, and swap it in directly if so.
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
