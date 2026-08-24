# frozen_string_literal: true
# Sort por defecto cronológico: el más RECIENTE primero.
# El consecutivo (issue_number) sigue siendo cronológico; solo cambia el orden de visualización.
module FibrazoIssuePerf
  module DefaultSortPatch
    def self.included(base)
      base.class_eval do
        def default_sort_criteria
          [['created_on', 'desc']]
        end
      end
    end
  end
end
IssueQuery.include FibrazoIssuePerf::DefaultSortPatch