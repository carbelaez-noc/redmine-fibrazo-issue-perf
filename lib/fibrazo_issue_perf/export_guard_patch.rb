# frozen_string_literal: true

# Mitiga 504/ALB 60s en exports pesados (XLSX/CSV I&M ~5k x muchas cols).
# - Elimina totales (t[]) en exports
# - Tope duro MAX_EXPORT_ROWS (2000): nunca se exportan más filas; se avisa con
#   los headers X-Export-Rows / X-Export-Truncated
# - CSV en streaming por batches (Enumerator + each_slice): no se construye el
#   string completo en memoria; lecturas DB por lotes
# - XLSX con lecturas por batches (el ZIP se sigue bufferizando en memoria por
#   limitación de write_xlsx: no soporta streaming real)
# - Si el export es pesado: genera CSV/XLSX batch rápido con UTF-8 BOM + nombre fechado
# - Async diferido (202 + job en background): PENDIENTE, ver docs/EXPORT_CAP_ASYNC_PENDING.md
require "csv"

module FibrazoIssuePerf
  # Lógica pura del tope de exportación (sin dependencias Rails: testeable).
  module ExportCap
    # Mínimo entre los candidatos; ignora nil/cero/negativos/no numéricos.
    # Retorna nil si no hay ningún candidato válido.
    def self.effective_cap(*candidates)
      vals = candidates.map do |v|
        begin
          n = Integer(v)
          n > 0 ? n : nil
        rescue StandardError
          nil
        end
      end.compact
      vals.min
    end

    # Parte ids en [capped, truncated?].
    def self.truncate_ids(ids, cap)
      ids = Array(ids)
      cap = cap.to_i
      return [ids, false] if cap <= 0 || ids.size <= cap
      [ids.first(cap), true]
    end
  end

  module ExportGuardPatch
    # Tope duro de filas por export (CSV y XLSX). Gana sobre
    # Setting.issues_export_limit y FIBRAZO_EXPORT_HARD_CAP.
    MAX_EXPORT_ROWS = 2000
    # Tamaño de lote para lecturas DB y chunks del stream CSV.
    CSV_BATCH_SIZE = 500

    SYNC_MAX_DEFAULT = 1000
    SYNC_MAX_WIDE_DEFAULT = 500

    def index
      fmt = params[:format].to_s
      if %w[xlsx csv].include?(fmt)
        strip_export_totals!
        ensure_query_for_export_guard!
        if @query && (heavy_export?(@query) || @query.issue_count.to_i > MAX_EXPORT_ROWS)
          Rails.logger.info(
            "[fibrazo_issue_perf] fast_csv_export user=#{User.current&.id} " \
            "count=#{@query.issue_count} cols=#{Array(@query.column_names).size} fmt=#{fmt}"
          )
          begin
            return send_fast_export!(@query, fmt)
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

    # Columnas sanas del query (excluye las que revientan caption).
    def export_columns(query)
      bad = []
      cols = query.columns.reject do |c|
        begin
          c.caption.to_s
          false
        rescue NameError, StandardError => e
          bad << [c.name.to_s, e.class.to_s].join(":")
          true
        end
      end
      Rails.logger.warn("[fibrazo_issue_perf] fast_export columnas excluidas: " + bad.join(", ")) if bad.any?
      cols
    end

    # Aplica el tope duro: [ids_recortados, truncated?, total].
    def capped_issue_ids(all_ids)
      all_ids = Array(all_ids)
      export_limit = Setting.issues_export_limit.to_i
      export_limit = 10_000 if export_limit <= 0
      env_cap = begin
        Integer(ENV.fetch("FIBRAZO_EXPORT_HARD_CAP", MAX_EXPORT_ROWS.to_s))
      rescue StandardError
        MAX_EXPORT_ROWS
      end
      cap = ExportCap.effective_cap(export_limit, env_cap, MAX_EXPORT_ROWS) || MAX_EXPORT_ROWS
      capped, truncated = ExportCap.truncate_ids(all_ids, cap)
      [capped, truncated, all_ids.size]
    end

    def set_export_headers!(rows, truncated)
      response.headers["X-Export-Rows"] = rows.to_i.to_s
      response.headers["X-Export-Truncated"] = truncated ? "true" : "false"
    end

    def utf8_cell(str)
      str.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
    end

    def custom_values_map(cf_ids, batch_ids)
      map = Hash.new { |h, k| h[k] = {} }
      return map if cf_ids.empty? || batch_ids.empty?

      CustomValue.where(customized_type: "Issue", customized_id: batch_ids, custom_field_id: cf_ids)
                 .pluck(:customized_id, :custom_field_id, :value)
                 .each { |iid, cfid, val| map[iid][cfid] = val }
      map
    end

    # CSV en streaming: headers HTTP + Enumerator por batches. Nunca se arma el
    # string completo en memoria.
    def send_fast_csv_export!(query)
      columns = export_columns(query)
      all_ids = query.issue_ids
      issue_ids, truncated, _total = capped_issue_ids(all_ids)

      cf_cols = columns.select { |c| c.respond_to?(:custom_field) }
      cf_ids = cf_cols.map { |c| c.custom_field.id }
      includes = [:status, :tracker, :project, :priority, :assigned_to, :author, :fixed_version]

      filename = build_export_filename(query)
      response.headers["Content-Type"] = "text/csv; charset=utf-8"
      response.headers["Content-Disposition"] = "attachment; filename=\"#{filename}\""
      set_export_headers!(issue_ids.size, truncated)
      Rails.logger.info("[fibrazo_issue_perf] fast_csv_filename=#{filename} rows=#{issue_ids.size} truncated=#{truncated}")

      header_line = CSV.generate_line(columns.map { |c| utf8_cell(c.caption.to_s) }, force_quotes: true)
      self.response_body = Enumerator.new do |y|
        # UTF-8 with BOM so Excel Windows shows accents correctly
        y << "\uFEFF"
        y << header_line
        issue_ids.each_slice(CSV_BATCH_SIZE) do |batch_ids|
          cv_map = custom_values_map(cf_ids, batch_ids)
          issues_by_id = Issue.where(id: batch_ids).includes(includes).index_by(&:id)
          batch_ids.each do |iid|
            issue = issues_by_id[iid]
            next unless issue
            y << CSV.generate_line(columns.map { |c| fast_cell_value(c, issue, cv_map, iid) }, force_quotes: true)
          end
        end
      end
    rescue NameError => e
      Rails.logger.error("[fibrazo_issue_perf] fast_csv NameError at send: " + e.class.to_s + " " + e.message.to_s[0, 200])
      raise
    end

    def send_fast_export!(query, fmt)
      if fmt.to_s == "xlsx"
        send_fast_xlsx_export!(query)
      else
        send_fast_csv_export!(query)
      end
    end

    def fast_export_dataset(query)
      columns = export_columns(query)
      all_ids = query.issue_ids
      issue_ids, truncated, _total = capped_issue_ids(all_ids)

      cf_cols = columns.select { |c| c.respond_to?(:custom_field) }
      cf_ids = cf_cols.map { |c| c.custom_field.id }
      cv_map = custom_values_map(cf_ids, issue_ids)

      includes = [:status, :tracker, :project, :priority, :assigned_to, :author, :fixed_version]
      issues_by_id = {}
      issue_ids.each_slice(CSV_BATCH_SIZE) do |batch_ids|
        issues_by_id.merge!(Issue.where(id: batch_ids).includes(includes).index_by(&:id))
      end
      [columns, issue_ids, cv_map, issues_by_id, truncated]
    end

    def fast_cell_value(c, issue, cv_map, iid)
      raw =
        if c.respond_to?(:custom_field)
          cv_map[iid][c.custom_field.id].to_s
        else
          csv_value_fast(c, issue, serialize_export_collection(c.value(issue), issue))
        end
      raw.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
    rescue NameError, StandardError
      ""
    end

    # Colecciones (seguidores, ficheros, relaciones) como texto legible, nunca #<...>.
    def serialize_export_collection(value, issue = nil)
      records =
        if value.is_a?(ActiveRecord::Relation)
          value.to_a
        elsif value.is_a?(Array) && value.first.is_a?(ApplicationRecord)
          value
        else
          return value
        end
      records.map do |r|
        if r.is_a?(Attachment)
          r.filename.to_s
        elsif defined?(Principal) && r.is_a?(Principal)
          r.name.to_s
        elsif r.is_a?(Issue)
          "##{r.id} #{r.subject}"
        elsif r.is_a?(IssueRelation)
          other = issue ? r.other_issue(issue) : nil
          other ? "#{r.relation_type} ##{other.id} #{other.subject}" : r.relation_type.to_s
        elsif r.is_a?(Journal)
          r.notes.to_s.truncate(120)
        else
          (r.respond_to?(:name) ? r.name : r.to_s).to_s
        end
      end.join(", ")
    end

    def send_fast_xlsx_export!(query)
      require "write_xlsx"
      columns, issue_ids, cv_map, issues_by_id, truncated = fast_export_dataset(query)
      set_export_headers!(issue_ids.size, truncated)
      io = StringIO.new
      workbook = WriteXLSX.new(io)
      worksheet = workbook.add_worksheet
      header_fmt = workbook.add_format(bold: 1)
      columns.each_with_index do |c, idx|
        worksheet.write_string(0, idx, c.caption.to_s)
      end
      # worksheet.freeze_panes(1, 0)  # opcional; se omite por compatibilidad
      row = 1
      issue_ids.each do |iid|
        issue = issues_by_id[iid]
        next unless issue
        columns.each_with_index do |c, idx|
          worksheet.write_string(row, idx, fast_cell_value(c, issue, cv_map, iid))
        end
        row += 1
      end
      # worksheet.set_column(0, columns.size - 1, 22) if columns.any?  # opcional
      workbook.close
      filename = build_export_filename(query).sub(/\.csv\z/, ".xlsx")
      Rails.logger.info("[fibrazo_issue_perf] fast_xlsx_filename=#{filename} rows=#{row - 1} truncated=#{truncated}")
      send_data io.string,
                type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                filename: filename,
                disposition: "attachment"
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
