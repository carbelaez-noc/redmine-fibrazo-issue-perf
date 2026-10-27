# frozen_string_literal: true

Redmine::Plugin.register :fibrazo_issue_perf do
  name 'Fibrazo Issue Perf'
  author 'Fibrazo'
  description 'Split lazy-load + export guard con tope duro (2000) y streaming CSV por batches'
  version '0.2.3'
  requires_redmine version_or_higher: '5.0.0'
end

require_relative 'lib/fibrazo_issue_perf/asset_sync'
require_relative 'lib/fibrazo_issue_perf/hooks'
require_relative 'lib/fibrazo_issue_perf/issues_controller_patch'

Rails.application.config.after_initialize do
  Rails.application.config.assets.precompile += %w[fibrazo_lazy_edit.js]
  FibrazoIssuePerf::AssetSync.sync!
rescue StandardError
  nil
end

require_relative 'lib/fibrazo_issue_perf/default_sort_patch'

# Export guard must prepend AFTER xlsx plugin (alphabetical load order).
Rails.application.config.after_initialize do
  require_relative 'lib/fibrazo_issue_perf/export_guard_patch'
rescue StandardError => e
  Rails.logger.error("[fibrazo_issue_perf] export_guard load failed: #{e.class}: #{e.message}")
end
