# frozen_string_literal: true

# Mitiga 504/ALB 60s en exports pesados (XLSX/CSV I&M ~5k x muchas cols).
# - Elimina totales (t[]) en exports
# - Si el export es pesado: genera CSV batch rápido con UTF-8 BOM + nombre fechado
# - Evita dejar un worker Puma pegado 60s+ después del corte del ALB
require "csv"

module FibrazoIssuePerf
  module ExportGuardPatch
    SYNC_MAX_DEFAULT = 1000
    SYNC_MAX_WIDE_DEFAULT = 500

    def index
      fmt = params[:format].to_s
      if %w[xlsx csv].include?(fmt)
        strip_export_totals!
        ensure_query_for_export_guard!
        if @query && heavy_export?(@query)
          Rails.logger.info(
            "[fibrazo_issue_perf] fast_csv_export user=#{User.current&.id} " \
            "count=#{@query.issue_count} cols=#{Array(@query.column_names).size} fmt=#{fmt}"
          )
          begin
            return send_fast_csv_export!(@query)
          rescue NameError, StandardError => e
            Rails.logger.error("[fibrazo_issue_perf] fast_csv FAILED: " + e.class.to_s + " " + e.message.to_s[0, 200])
          end
        end
      end

      super
    end

    private

    def strip_export_totals!
      params.delete(:t)
      params.delete("t")
      if request.respond_to?(:query_parameters)
        request.query_parameters.delete("t")
        request.query_parameters.delete(:t)
      end
    rescue StandardError
      nil
    end

    def ensure_query_for_export_guard!
      return if @query
      retrieve_query
    rescue StandardError => e
      Rails.logger.warn("[fibrazo_issue_perf] export_guard retrieve_query: #{e.class}: #{e.message}")
    end

    def xlsx_sync_max
      Integer(ENV.fetch("FIBRAZO_XLSX_SYNC_MAX", SYNC_MAX_DEFAULT))
    rescue StandardError
      SYNC_MAX_DEFAULT
    end

    def xlsx_sync_max_wide
      Integer(ENV.fetch("FIBRAZO_XLSX_SYNC_MAX_WIDE", SYNC_MAX_WIDE_DEFAULT))
    rescue StandardError
      SYNC_MAX_WIDE_DEFAULT
    end

    def heavy_export?(query)
      cnt = query.issue_count.to_i
      cols = Array(query.column_names).size
      return true if cnt > xlsx_sync_max
      return true if cols >= 15 && cnt > xlsx_sync_max_wide
      false
    rescue StandardError
      true
    end
    alias xlsx_too_heavy? heavy_export?

    def send_fast_csv_export!(query)
      columns = query.columns
      bad = []
      columns = columns.reject do |c|
        begin
          c.caption.to_s
          false
        rescue NameError, StandardError => e
          bad << [c.name.to_s, e.class.to_s].join(":")
          true
        end
      end
      Rails.logger.warn("[fibrazo_issue_perf] fast_csv columnas excluidas: " + bad.join(", ")) if bad.any?
      issue_ids = query.issue_ids
      export_limit = Setting.issues_export_limit.to_i
      export_limit = 10_000 if export_limit <= 0
      hard_cap = Integer(ENV.fetch("FIBRAZO_EXPORT_HARD_CAP", "20000"))
      issue_ids = issue_ids.first([export_limit, hard_cap].min)

      cf_cols = columns.select { |c| c.respond_to?(:custom_field) }
      cf_ids = cf_cols.map { |c| c.custom_field.id }

      cv_map = Hash.new { |h, k| h[k] = {} }
      if cf_ids.any? && issue_ids.any?
        CustomValue.where(customized_type: "Issue", customized_id: issue_ids, custom_field_id: cf_ids)
                   .pluck(:customized_id, :custom_field_id, :value)
                   .each { |iid, cfid, val| cv_map[iid][cfid] = val }
      end

      includes = [:status, :tracker, :project, :priority, :assigned_to, :author, :fixed_version]
      # UTF-8 with BOM so Excel Windows shows accents correctly
      body = +""
      body << "\uFEFF"
      body << CSV.generate(force_quotes: true, encoding: Encoding::UTF_8) do |out|
        out << columns.map { |c| c.caption.to_s.encode("UTF-8", invalid: :replace, undef: :replace) }
        issues_by_id = Issue.where(id: issue_ids).includes(includes).index_by(&:id)
        issue_ids.each do |iid|
          issue = issues_by_id[iid]
          next unless issue
          out << columns.map do |c|
            begin
              raw =
                if c.respond_to?(:custom_field)
                  cv_map[iid][c.custom_field.id].to_s
                else
                  csv_value_fast(c, issue, c.value(issue))
                end
              raw.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
            rescue NameError, StandardError
              ""
            end
          end
        end
      end

      filename = build_export_filename(query)
      Rails.logger.info("[fibrazo_issue_perf] fast_csv_filename=#{filename}")
      send_data body,
                type: "text/csv; charset=utf-8",
                filename: filename,
                disposition: "attachment"
    rescue NameError => e
      Rails.logger.error("[fibrazo_issue_perf] fast_csv NameError at send: " + e.class.to_s + " " + e.message.to_s[0, 200])
      raise
    end

    def resolve_export_query_id
      qid = params[:query_id].presence || params["query_id"].presence
      return qid if qid.present?

      ref = request.referer.to_s
      if (m = ref.match(/[?&]query_id=(\d+)/))
        return m[1]
      end

      # Redmine sometimes keeps last used query in session
      sess_qid = session[:query]&.dig(:id) || session[:query]&.dig("id")
      return sess_qid if sess_qid.present?

      nil
    rescue StandardError
      nil
    end

    def build_export_filename(query)
      stamp = Time.zone.now.strftime("%Y%m%d_%H%M%S")
      q = query
      qid = resolve_export_query_id

      if q.name.to_s.strip.blank? && qid.present?
        q = IssueQuery.find_by(id: qid) || query
      end

      qname = q.name.to_s.strip
      qname = params[:export_query_name].to_s.strip if qname.blank? && params[:export_query_name].present?
      qname = "query_#{qid}" if qname.blank? && qid.present?
      qname = "issues" if qname.blank?

      safe = qname.unicode_normalize(:nfd).gsub(/\p{Mn}/, "")
                  .gsub(/[^\w\-]+/, "_").gsub(/_+/, "_").gsub(/\A_|_\z/, "")
      safe = "issues" if safe.blank?
      kind = params[:format].to_s == "xlsx" ? "xlsx_request" : "csv"
      "#{safe}_#{kind}_#{stamp}.csv"
    end

    def csv_value_fast(_column, _issue, value)
      case value
      when Array
        value.map { |v| csv_value_fast(nil, nil, v) }.join(", ")
      when Time, DateTime, ActiveSupport::TimeWithZone
        value.in_time_zone("America/Bogota").strftime("%Y-%m-%d %H:%M:%S")
      when Date
        value.strftime("%Y-%m-%d")
      when true then "1"
      when false then "0"
      else
        value.to_s.gsub(/\r\n?/, "\n")
      end
    rescue StandardError
      value.to_s
    end
  end
end

unless IssuesController.ancestors.include?(FibrazoIssuePerf::ExportGuardPatch)
  IssuesController.prepend(FibrazoIssuePerf::ExportGuardPatch)
end
