# frozen_string_literal: true

# Prueba del tope duro de exports (MAX_EXPORT_ROWS) y headers X-Export-*.
# Corre sin Rails: define fakes mínimos y carga el patch real.
#
#   ruby -Itest test/test_export_cap.rb
require "minitest/autorun"
require "csv"
require "ostruct"

# ---- Fakes mínimos del entorno Rails/Redmine ----

module ActiveSupport
  class TimeWithZone < Time; end
end

module Rails
  def self.logger
    @logger ||= Logger.new(IO::NULL)
  end
end
require "logger"

# Mínimo de ActiveSupport usado por el patch.
class Object
  def blank?
    respond_to?(:empty?) ? !!empty? : !self
  end

  def present?
    !blank?
  end

  def presence
    self if present?
  end
end

class NilClass
  def blank?
    true
  end
end

class FalseClass
  def blank?
    true
  end
end

class String
  def blank?
    strip.empty?
  end
end

module Setting
  class << self
    attr_accessor :issues_export_limit
  end
  self.issues_export_limit = 10_000
end

class FakeColumn
  attr_reader :name
  def initialize(name)
    @name = name
  end

  def caption
    @name
  end

  def value(issue)
    "subject-#{issue.id}"
  end
end

FakeIssue = Struct.new(:id)

class FakeRelation
  def initialize(ids)
    @ids = ids
  end

  def includes(*)
    self
  end

  def index_by
    @ids.map { |i| FakeIssue.new(i) }.to_h { |issue| [issue.id, issue] }
  end
end

class Issue
  def self.where(id:)
    FakeRelation.new(Array(id))
  end
end

class FakePluck
  def pluck(*)
    []
  end
end

class CustomValue
  def self.where(*, **)
    FakePluck.new
  end
end

class FakeRequest
  def referer
    nil
  end

  def query_parameters
    {}
  end
end

class FakeResponse
  attr_accessor :headers

  def initialize
    @headers = {}
  end
end

# IssuesController dummy para el prepend al final del archivo del patch.
class IssuesController; end

require_relative "../lib/fibrazo_issue_perf/export_guard_patch"

class FakeController
  include FibrazoIssuePerf::ExportGuardPatch

  attr_accessor :params, :query

  def response
    @response ||= FakeResponse.new
  end

  def response_body=(body)
    @stream = body
  end

  def stream_chunks
    raise "sin response_body" unless @stream

    out = []
    @stream.each { |chunk| out << chunk }
    out
  end

  def request
    FakeRequest.new
  end

  def session
    {}
  end

  # build_export_filename usa Time.zone; aquí devolvemos hora real.
end

module TimeZoneFake
  def self.now
    Time.now
  end
end

module TimeZoneStub
  def zone
    ::TimeZoneFake
  end
end
Time.extend(TimeZoneStub)

class FakeQuery
  attr_reader :ids

  def initialize(ids)
    @ids = ids
  end

  def columns
    [FakeColumn.new("ID"), FakeColumn.new("Subject")]
  end

  def issue_ids
    @ids
  end

  def issue_count
    @ids.size
  end

  def column_names
    %w[id subject]
  end

  def name
    "TestQuery"
  end
end

class ExportCapTest < Minitest::Test
  CAP = FibrazoIssuePerf::ExportGuardPatch::MAX_EXPORT_ROWS

  def setup
    Setting.issues_export_limit = 10_000
    ENV.delete("FIBRAZO_EXPORT_HARD_CAP")
    @ctrl = FakeController.new
    @ctrl.params = { format: "csv" }
  end

  def test_truncate_headers_and_row_count
    q = FakeQuery.new((1..(CAP + 500)).to_a)
    @ctrl.send(:send_fast_csv_export!, q)

    headers = @ctrl.response.headers
    assert_equal CAP.to_s, headers["X-Export-Rows"], "header X-Export-Rows"
    assert_equal "true", headers["X-Export-Truncated"], "header X-Export-Truncated"

    body = @ctrl.stream_chunks.join
    rows = CSV.parse(body.delete_prefix("\uFEFF"))
    assert_equal CAP + 1, rows.size, "header + CAP filas de datos"
    assert_equal %w[ID Subject], rows.first
  end

  def test_no_truncate_small_export
    q = FakeQuery.new((1..10).to_a)
    @ctrl.send(:send_fast_csv_export!, q)

    headers = @ctrl.response.headers
    assert_equal "10", headers["X-Export-Rows"]
    assert_equal "false", headers["X-Export-Truncated"]

    body = @ctrl.stream_chunks.join
    rows = CSV.parse(body.delete_prefix("\uFEFF"))
    assert_equal 11, rows.size
  end

  def test_hard_cap_wins_over_setting_and_env
    Setting.issues_export_limit = 50_000
    ENV["FIBRAZO_EXPORT_HARD_CAP"] = "20_000".delete("_")
    q = FakeQuery.new((1..5000).to_a)
    @ctrl.send(:send_fast_csv_export!, q)

    headers = @ctrl.response.headers
    assert_equal CAP.to_s, headers["X-Export-Rows"]
    assert_equal "true", headers["X-Export-Truncated"]

    body = @ctrl.stream_chunks.join
    rows = CSV.parse(body.delete_prefix("\uFEFF"))
    assert_equal CAP + 1, rows.size
  ensure
    ENV.delete("FIBRAZO_EXPORT_HARD_CAP")
  end

  def test_export_cap_pure_helpers
    cap = FibrazoIssuePerf::ExportCap
    assert_equal 2000, cap.effective_cap(10_000, 20_000, 2000)
    assert_equal 500, cap.effective_cap(500, 20_000, 2000)
    assert_nil cap.effective_cap(0, -1, "xx")

    capped, truncated = cap.truncate_ids([1, 2, 3], 2000)
    assert_equal [1, 2, 3], capped
    refute truncated

    capped, truncated = cap.truncate_ids((1..2500).to_a, 2000)
    assert_equal 2000, capped.size
    assert truncated
  end

  def test_streaming_does_not_build_full_string
    # El cuerpo debe ser un Enumerator lazy (streaming), no un String.
    q = FakeQuery.new((1..100).to_a)
    @ctrl.send(:send_fast_csv_export!, q)
    stream = @ctrl.instance_variable_get(:@stream)
    assert_kind_of Enumerator, stream
  end
end
