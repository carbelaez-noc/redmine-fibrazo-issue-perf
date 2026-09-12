# frozen_string_literal: true

module FibrazoIssuePerf
  module AdminOnlyQueriesPatch
    ADMIN_ONLY_QUERY_IDS = [16].freeze

    module ClassMethods
      def visible(*args)
        user = args.first.is_a?(User) ? args.first : User.current
        rel = super
        if user&.admin?
          # Ensure admin-only private queries are visible to every admin, not only owner.
          extras = where(id: ADMIN_ONLY_QUERY_IDS)
          return rel.or(extras)
        end
        rel.where.not(id: ADMIN_ONLY_QUERY_IDS)
      end
    end

    def visible?(user = User.current)
      if FibrazoIssuePerf::AdminOnlyQueriesPatch::ADMIN_ONLY_QUERY_IDS.include?(id)
        return !!user&.admin?
      end
      super
    end
  end
end

unless IssueQuery.singleton_class.ancestors.include?(FibrazoIssuePerf::AdminOnlyQueriesPatch::ClassMethods)
  IssueQuery.singleton_class.prepend(FibrazoIssuePerf::AdminOnlyQueriesPatch::ClassMethods)
  IssueQuery.prepend(FibrazoIssuePerf::AdminOnlyQueriesPatch)
end
