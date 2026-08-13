# frozen_string_literal: true

module FibrazoIssuePerf
  module IssuesControllerPatch
    # Prepend so we can short-circuit authorize for lazy_edit_form without
    # clobbering the existing before_action :authorize except: list via skip_before_action.
    def authorize(ctrl = params[:controller], action = params[:action], global = false)
      if action.to_s == 'lazy_edit_form'
        # find_issue runs only for show/edit/update/issue_tab; load here for this action.
        find_issue unless @issue
        return deny_access unless @issue&.editable?

        return true
      end
      super
    end

    # Fragment used by show page to inject #update contents on first Edit/Reply.
    def lazy_edit_form
      find_issue unless @issue
      return deny_access unless @issue&.editable?

      @priorities = IssuePriority.active
      @allowed_statuses = @issue.new_statuses_allowed_to(User.current)
      if User.current.allowed_to?(:log_time, @project)
        @time_entry ||= TimeEntry.new(issue: @issue, project: @issue.project)
      else
        @time_entry = nil
      end

      render partial: 'edit', layout: false
    end
  end
end

unless IssuesController.ancestors.include?(FibrazoIssuePerf::IssuesControllerPatch)
  IssuesController.prepend(FibrazoIssuePerf::IssuesControllerPatch)
end
