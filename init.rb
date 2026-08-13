# frozen_string_literal: true

Redmine::Plugin.register :fibrazo_issue_perf do
  name 'Fibrazo Issue Perf'
  author 'Fibrazo'
  description 'Lazy-load issue edit form on show to cut HTML payload for concurrent users'
  version '0.1.10'
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
