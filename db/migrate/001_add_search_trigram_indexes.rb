# frozen_string_literal: true

# Indices trigram (pg_trgm) para busqueda global /search con ILIKE '%q%'.
# GIN trigram convierte el LIKE con wildcard lider en Bitmap Index Scan en
# vez de Seq Scan. CONCURRENTLY: sin bloqueos de escritura. Solo DDL: no
# requiere restart del web/worker.
class AddSearchTrigramIndexes < ActiveRecord::Migration[6.1]
  disable_ddl_transaction!

  INDEXES = [
    ['idx_issues_subject_trgm', 'issues', 'subject', nil],
    ['idx_issues_description_trgm', 'issues', 'description', nil],
    ['idx_journals_notes_trgm', 'journals', 'notes', nil],
    ['idx_custom_values_value_trgm', 'custom_values', 'value', "customized_type = 'Issue'"],
    ['idx_attachments_filename_trgm', 'attachments', 'filename', nil]
  ].freeze

  def up
    enable_extension 'pg_trgm' unless extension_enabled?('pg_trgm')
    INDEXES.each do |name, table, column, predicate|
      sql = "CREATE INDEX CONCURRENTLY IF NOT EXISTS #{name} ON #{table} USING gin (#{column} gin_trgm_ops)"
      sql += " WHERE #{predicate}" if predicate
      execute sql
    end
  end

  def down
    INDEXES.each do |name, _table, _column, _predicate|
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{name}"
    end
  end
end
