source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
# Individual framework gems (not the "rails" meta-gem) so ActiveStorage/ActionText/
# ActionMailbox never resolve into Gemfile.lock at all (see ADR-0011) — only the frameworks
# actually required in config/application.rb.
gem "railties", "~> 8.1.3"
gem "activesupport", "~> 8.1.3"
gem "activemodel", "~> 8.1.3"
gem "activerecord", "~> 8.1.3"
gem "actionpack", "~> 8.1.3"
gem "actionview", "~> 8.1.3"
gem "activejob", "~> 8.1.3"
gem "actioncable", "~> 8.1.3"
gem "actionmailer", "~> 8.1.3"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"
# Build JSON APIs with ease [https://github.com/rails/jbuilder]
gem "jbuilder"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Claude API client, used for job-requirement extraction and bullet rewriting
gem "ruby_llm"
# Render the ATS-friendly CV template to PDF
gem "prawn"
# Extract text from LinkedIn PDF data exports
gem "pdf-reader"

# OAuth 2.0 client framework, used for Google sign-in
gem "omniauth"
# Google OAuth2 strategy for omniauth
gem "omniauth-google-oauth2"
# CSRF protection for OmniAuth's request phase (OmniAuth 2.x no longer includes this itself)
gem "omniauth-rails_csrf_protection"

# Stripe Checkout for credit packs and the unlimited window
gem "stripe"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"

  # Track test coverage [https://github.com/simplecov-ruby/simplecov]
  gem "simplecov", require: false
end
