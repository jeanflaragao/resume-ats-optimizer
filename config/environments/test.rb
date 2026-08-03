# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with cache-control for performance.
  config.public_file_server.headers = { "cache-control" => "public, max-age=3600" }

  # Show full error reports.
  config.consider_all_requests_local = true
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment. Integration tests run in-process
  # and never render real forms or carry tokens, so this stays off for them. System tests do
  # render real forms in a real browser -- ApplicationSystemTestCase opts back in for the
  # duration of each example (see issue #57 / ADR-0013) rather than this being flipped
  # globally, which would fail every post in test/integration/ for no added signal.
  config.action_controller.allow_forgery_protection = false

  # Throwaway Active Record Encryption keys, so Resume::PdfRequest's `encrypts
  # :text` works without config/master.key. CI never has it -- the key is
  # gitignored (.gitignore:35) and .github/workflows/ci.yml sets no
  # RAILS_MASTER_KEY -- so credentials come back empty there and encrypting
  # would raise ActiveRecord::Encryption::Errors::Configuration.
  #
  # These win over the credentials lookup rather than racing it: activerecord's
  # "active_record_encryption.configuration" initializer splats
  # **app.config.active_record.encryption last (railtie.rb:361-367). Test data
  # is scratch space, so fixed literals here are correct -- the real keys have
  # no business being reachable from a public repo's CI.
  config.active_record.encryption.primary_key = "test_encryption_primary_key_do_not_reuse"
  config.active_record.encryption.deterministic_key = "test_encryption_deterministic_key_nope"
  config.active_record.encryption.key_derivation_salt = "test_encryption_key_derivation_salt_xx"

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "example.com" }

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true
end
