# frozen_string_literal: true

module FibrazoIssuePerf
  # Propshaft serves digested assets from public/assets + .manifest.json.
  # After plugin re-enable/restart the logical path can 404 and break Edit/Reply.
  module AssetSync
    LOGICAL = 'plugin_assets/fibrazo_issue_perf/fibrazo_lazy_edit.js'
    SRC_REL = 'assets/javascripts/fibrazo_lazy_edit.js'

    module_function

    def sync!
      plugin_root = Redmine::Plugin.find(:fibrazo_issue_perf).directory
      src = File.join(plugin_root, SRC_REL)
      return unless File.file?(src)

      content = File.binread(src)
      digest = Digest::MD5.hexdigest(content)[0, 8]
      dest_dir = Rails.public_path.join('assets/plugin_assets/fibrazo_issue_perf')
      FileUtils.mkdir_p(dest_dir)
      digested_name = "fibrazo_lazy_edit-#{digest}.js"
      File.binwrite(dest_dir.join(digested_name), content)
      File.binwrite(dest_dir.join('fibrazo_lazy_edit.js'), content) # undigested fallback

      manifest_path = Rails.public_path.join('assets/.manifest.json')
      return unless File.file?(manifest_path)

      manifest = JSON.parse(File.read(manifest_path))
      manifest[LOGICAL] = {
        'digested_path' => "plugin_assets/fibrazo_issue_perf/#{digested_name}",
        'integrity' => nil
      }
      File.write(manifest_path, JSON.generate(manifest))
      Rails.logger.info "FibrazoIssuePerf::AssetSync ok digest=#{digest}"
    rescue StandardError => e
      Rails.logger.warn "FibrazoIssuePerf::AssetSync failed: #{e.class} #{e.message}"
    end
  end
end
