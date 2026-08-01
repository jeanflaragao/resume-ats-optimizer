# ADR-0004: Use Prawn instead of Grover/Puppeteer for PDF generation

## Status
Accepted

## Context
Issue #12 required an ATS-friendly PDF template with deliberately narrow constraints: no
tables, no columns, no images, standard fonts — the layout properties that make a resume
parseable by Applicant Tracking Systems in the first place. Issue #1's architecture proposal
evaluated the PDF-generation approach against exactly this constraint set, since it directly
determines whether a heavier rendering pipeline is actually needed.

## Decision
Use Prawn — pure Ruby, programmatic PDF construction — rather than Grover (headless
Chrome/Puppeteer rendering HTML/CSS to PDF).

## Alternatives considered
- **Grover (Puppeteer/headless Chrome)**: capable of far more flexible layouts via arbitrary
  HTML/CSS, but that flexibility solves a harder problem than this project has — the required
  template is intentionally simple. Grover would also require bundling headless Chrome into the
  Kamal-deployed Docker image, increasing image size and memory footprint for a solo-maintainer
  single-VPS deploy. Rejected as solving for capability the product doesn't need at real
  operational cost.
- **wicked_pdf / other wkhtmltopdf-based tools**: not seriously evaluated — same
  HTML-to-PDF-via-external-binary shape as Grover, same rejected trade-off.

## Consequences
- `Resume::Pdf` (issue #12) is built directly against Prawn's flow-layout API: manual pagination
  handling (a private `ensure_space` helper using `height_of`/`cursor` so a section header can't
  be stranded alone at the bottom of a page), explicit color/accent management
  (`Resume::Pdf::ACCENT_COLOR` reserved for section headers/dividers only) — more manual than
  writing CSS, but proportionate to the template's actual complexity.
- The Docker image stays Node/Chrome-free, keeping the Kamal deploy lighter.
- `Resume::Pdf` reads only plain duck-typed attributes off `resume` (no ActiveRecord-specific
  calls), which is what let issue #13's `Resume::Optimization` feed it a non-persisted value
  object with zero changes to `Resume::Pdf` itself — an emergent benefit of Prawn's simplicity,
  not an explicit goal of this decision.
- If the product ever needs a visually richer template (multi-column, images, custom
  typography), this decision would need revisiting — Prawn's flow layout is not well-suited to
  that, and Grover-style HTML/CSS rendering would become the more natural fit.
