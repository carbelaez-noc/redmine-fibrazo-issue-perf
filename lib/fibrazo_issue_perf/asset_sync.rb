# frozen_string_literal: true

module FibrazoIssuePerf
  # Propshaft serves digested assets from public/assets + .manifest.json.
  # After plugin re-enable/restart the logical path can 404 and break Edit/Reply.
  module AssetSync
    FILES = [
      {
        logical: 'plugin_assets/fibrazo_issue_perf/fibrazo_lazy_edit.js',
        src_rel: 'assets/javascripts/fibrazo_lazy_edit.js',
        base: 'fibrazo_lazy_edit'
      },
      {
        logical: 'plugin_assets/fibrazo_issue_perf/fibrazo_export_filename.js',
        src_rel: 'assets/javascripts/fibrazo_export_filename.js',
        base: 'fibrazo_export_filename'
      }
    ].freeze

    module_function

    def sync!
      plugin_root = Redmine::Plugin.find(:fibrazo_issue_perf).directory
      dest_dir = Rails.public_path.join('assets/plugin_assets/fibrazo_issue_perf')
      FileUtils.mkdir_p(dest_dir)

      manifest_path = Rails.public_path.join('assets/.manifest.json')
      manifest = File.file?(manifest_path) ? JSON.parse(File.read(manifest_path)) : {}

      FILES.each do |spec|
        src = File.join(plugin_root, spec[:src_rel])
        next unless File.file?(src)

        content = File.binread(src)
        digest = Digest::MD5.hexdigest(content)[0, 8]
        digested_name = "#{spec[:base]}-#{digest}.js"
        File.binwrite(dest_dir.join(digested_name), content)
        File.binwrite(dest_dir.join("#{spec[:base]}.js"), content)

        manifest[spec[:logical]] = {
          'digested_path' => "plugin_assets/fibrazo_issue_perf/#{digested_name}",
          'integrity' => nil
        }
        Rails.logger.info "FibrazoIssuePerf::AssetSync ok #{spec[:base]} digest=#{digest}"
      end

      File.write(manifest_path, JSON.generate(manifest)) if File.file?(manifest_path) || manifest.any?
    rescue StandardError => e
      Rails.logger.warn "FibrazoIssuePerf::AssetSync failed: #{e.class} #{e.message}"
    end
  end
end
