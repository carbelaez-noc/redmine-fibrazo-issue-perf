# frozen_string_literal: true

module FibrazoIssuePerf
  class Hooks < Redmine::Hook::ViewListener
    def view_layouts_base_html_head(context = {})
      controller = context[:controller]
      return '' unless controller

      bits = []
      if controller.controller_name == 'issues' && controller.action_name.to_s == 'show'
        bits << javascript_include_tag('fibrazo_lazy_edit', plugin: 'fibrazo_issue_perf', defer: true)
      end
      if controller.controller_name == 'issues' && controller.action_name.to_s == 'index'
        bits << javascript_include_tag('fibrazo_export_filename', plugin: 'fibrazo_issue_perf', defer: true)
      end
      bits.join("\n").html_safe
    end
  end
end
