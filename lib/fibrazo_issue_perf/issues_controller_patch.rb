# frozen_string_literal: true

module FibrazoIssuePerf
  module IssuesControllerPatch
    def authorize(ctrl = params[:controller], action = params[:action], global = false)
      if action.to_s == 'lazy_edit_attributes'
        find_issue unless @issue
        return deny_access unless @issue&.editable?

        return true
      end
      super
    end

    # Solo propiedades/CFs del formulario (issues/_form). Notas+adjuntos ya van en show.
    def lazy_edit_attributes
      find_issue unless @issue
      return deny_access unless @issue&.editable?
      return head :forbidden unless @issue.attributes_editable?

      @priorities = IssuePriority.active
      @allowed_statuses = @issue.new_statuses_allowed_to(User.current)

      render partial: 'form', layout: false
    end
  end
end

unless IssuesController.ancestors.include?(FibrazoIssuePerf::IssuesControllerPatch)
  IssuesController.prepend(FibrazoIssuePerf::IssuesControllerPatch)
end
