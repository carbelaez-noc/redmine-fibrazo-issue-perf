# frozen_string_literal: true

# Evita listados/API/auto-refresh sobre issues cerrados (~94% de la tabla).
# /issues/:id (show) no pasa por aquí: se puede abrir un cerrado por ID.
module FibrazoIssuePerf
  module OpenOnlyListingsPatch
    OPEN_STATUS = {operator: 'o', values: ['']}.freeze

    module InstanceMethods
      def build_from_params(params, defaults = {})
        super
        fibrazo_coerce_status_to_open!
        self
      end

      def issues(options = {})
        fibrazo_coerce_status_to_open!
        super
      end

      def issue_count
        fibrazo_coerce_status_to_open!
        super
      end

      def issue_ids(options = {})
        fibrazo_coerce_status_to_open!
        super
      end

      def base_scope
        fibrazo_coerce_status_to_open!
        super
      end

    # Sin filtro de estado → solo abiertos: evita listados/API/auto-refresh
    # sobre el ~94% cerrado de la tabla. Con filtro explícito del usuario
    # (incluye Cerrado o Todos) se respeta tal cual.
    def fibrazo_coerce_status_to_open!
      return if fibrazo_allow_closed_listings?
      return if @fibrazo_open_only_coerced

      @fibrazo_open_only_coerced = true
      self.filters ||= {}
      filters['status_id'] = OPEN_STATUS.dup unless filters.key?('status_id')
    rescue StandardError => e
      Rails.logger.warn("[fibrazo_issue_perf] open-only coerce failed: #{e.class}: #{e.message}") if Rails.logger
    end

      def fibrazo_allow_closed_listings?
        return true if defined?(::RequestStore) && ::RequestStore.store[:fibrazo_allow_closed_listings]
        false
      end
    end

    def self.apply!
      return if IssueQuery.ancestors.include?(InstanceMethods)

      IssueQuery.prepend(InstanceMethods)
    end
  end
end

FibrazoIssuePerf::OpenOnlyListingsPatch.apply!
