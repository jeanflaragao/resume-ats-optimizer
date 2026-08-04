# Issue #59. Thin wrapper around Resume.purge_stale! so config/recurring.yml
# can schedule it as a `class:` entry, per the issue's own proposal, and so
# the destroyed-record counts -- an explicit acceptance criterion -- land in
# the log. The purge logic itself stays on the model (Resume.purge_stale!),
# matching the sibling Resume::PdfRequest.purge_stale! / Usage::Counter.
# purge_stale! pattern rather than introducing a different shape for this one
# purge. ADR-0026 has the retention-window reasoning.
class Resume::PurgeStaleJob < ApplicationJob
  queue_as :default

  def perform
    counts = Resume.purge_stale!
    Rails.logger.info(
      "Resume::PurgeStaleJob: purged #{counts[:claimed]} claimed, #{counts[:orphan]} orphaned resume(s)"
    )
  end
end
