# spec/support/telemetry_sqlite.cr
require "../spec_helper"
require "../../src/llm-chord/telemetry-sqlite"
require "llm-telemetry/testing"

alias Testing = LLM::Telemetry::Testing
alias ManualClock = LLM::Telemetry::Testing::ManualClock

class Gate
  @channel = Channel(Nil).new

  def open : Nil
    @channel.close
  end

  def wait : Nil
    @channel.receive?
  end
end

class CountingExecutor < Sqlite::Executor
  def initialize(@inner : Sqlite::Executor, @spy : SpyDatabase); end

  def exec(sql : String) : Nil
    @inner.exec(sql)
  end

  def run_values(sql : String, params : Array(Sqlite::Value)) : Nil
    @inner.run_values(sql, params)
  end

  def get_values(sql : String, params : Array(Sqlite::Value)) : Sqlite::Row?
    @inner.get_values(sql, params)
  end

  def all_values(sql : String, params : Array(Sqlite::Value)) : Array(Sqlite::Row)
    @spy.queries += 1
    @inner.all_values(sql, params)
  end
end

class SpyDatabase < Sqlite::Database
  getter inner : Sqlite::Sqlite3Database
  property transactions = 0
  getter maximum_active = 0
  property queries = 0
  property before_transaction : Proc(Nil)? = nil
  property failure : Exception? = nil
  @active = 0

  def initialize(@inner : Sqlite::Sqlite3Database); end

  def exec(sql : String) : Nil
    @inner.exec(sql)
  end

  def run_values(sql : String, params : Array(Sqlite::Value)) : Nil
    @inner.run_values(sql, params)
  end

  def get_values(sql : String, params : Array(Sqlite::Value)) : Sqlite::Row?
    @inner.get_values(sql, params)
  end

  def all_values(sql : String, params : Array(Sqlite::Value)) : Array(Sqlite::Row)
    @inner.all_values(sql, params)
  end

  def transaction(&)
    @transactions += 1
    @active += 1
    @maximum_active = Math.max(@maximum_active, @active)
    begin
      @before_transaction.try &.call
      @failure.try { |error| raise error }
      @inner.transaction { |transaction| yield CountingExecutor.new(transaction, self) }
    ensure
      @active -= 1
    end
  end

  def close : Nil
    @inner.close
  end
end

class TelemetryFixture
  getter db : SpyDatabase
  getter telemetry : SqliteTelemetry

  def initialize(clock : LLM::Telemetry::Clock = LLM::Telemetry::SYSTEM_CLOCK, retention : Time::Span = SqliteTelemetry::DEFAULT_RETENTION,
                 max_queued_spans : Int32 = SqliteTelemetry::DEFAULT_MAX_QUEUED_SPANS)
    @db = SpyDatabase.new(Sqlite.open_database(":memory:"))
    @telemetry = LLM::Chord.create_sqlite_telemetry(@db, retention: retention, max_queued_spans: max_queued_spans, clock: clock)
    @db.transactions = 0
  end

  def close : Nil
    @telemetry.close
  ensure
    @db.close
  end
end

def with_telemetry(clock : LLM::Telemetry::Clock = LLM::Telemetry::SYSTEM_CLOCK, retention : Time::Span = SqliteTelemetry::DEFAULT_RETENTION,
                   max_queued_spans : Int32 = SqliteTelemetry::DEFAULT_MAX_QUEUED_SPANS, &)
  fixture = TelemetryFixture.new(clock, retention, max_queued_spans)
  begin
    yield fixture
  ensure
    fixture.close rescue nil
  end
end

def span_options(name : String, attributes : LLM::Telemetry::Attributes? = nil, links : Array(LLM::Telemetry::SpanLink)? = nil) : LLM::Telemetry::SpanOptions
  LLM::Telemetry::SpanOptions.new(name, attributes, links)
end

def attributes_of(json : JSON::Any) : LLM::Telemetry::Attributes
  result = LLM::Telemetry::Attributes.new
  json.as_h.each do |key, value|
    result[key] = case raw = value.raw
                  when String, Int64, Float64, Bool then raw
                  when Array
                    items = raw.map(&.raw)
                    if items.all?(String)
                      items.map(&.as(String))
                    elsif items.all?(Bool)
                      items.map(&.as(Bool))
                    elsif items.all?(Int64)
                      items.map(&.as(Int64))
                    else
                      items.map(&.as(Int64 | Float64).to_f64)
                    end
                  else raise "unexpected attribute #{value.inspect}"
                  end
  end
  result
end

def pick(row : Sqlite::Row?, *keys : String) : Sqlite::Row
  result = Sqlite::Row.new
  keys.each { |key| result[key] = row.not_nil![key] }
  result
end

class SqliteAdapterFixture < Testing::AdapterFixture
  getter fixture = TelemetryFixture.new

  def context : LLM::Telemetry::TelemetryContext
    fixture.telemetry
  end

  def propagation : LLM::Telemetry::Propagation?
    fixture.telemetry.propagation
  end

  def recorded_spans : Array(LLM::Telemetry::RecordedSpan)
    fixture.telemetry.flush
    fixture.db.all("SELECT rowid, * FROM telemetry_spans").map { |row| recorded(row) }.sort_by!(&.id)
  end

  def close : Nil
    fixture.close
  end

  private def recorded(row : Sqlite::Row) : LLM::Telemetry::RecordedSpan
    id = row["id"].as(String)
    trace_id = row["trace_id"].as(String)
    parent = row["parent_id"].as(String?)
    scope, sequence = id.split(':', 2)
    parent_id = parent.try(&.split(':', 2)).try { |(parent_scope, parent_sequence)| parent_scope == scope ? parent_sequence.to_i64 : nil }
    links = JSON.parse(row["links"].as(String)).as_a.map do |link|
      LLM::Telemetry::RecordedLink.new(carrier(link["span_id"].as_s, link["trace_id"].as_s), attributes_of(link["attributes"]))
    end
    events = JSON.parse(row["events"].as(String)).as_a.map do |event|
      LLM::Telemetry::RecordedEvent.new(event["name"].as_s, attributes_of(event["attributes"]))
    end
    LLM::Telemetry::RecordedSpan.new(sequence.to_i64, parent_id, carrier(id, trace_id), parent.try { |value| carrier(value, trace_id) },
      links, row["name"].as(String), attributes_of(JSON.parse(row["attributes"].as(String))), events,
      status(JSON.parse(row["status"].as(String))), true, row["rowid"].as(Int64))
  end

  private def carrier(span_id : String, trace_id : String) : LLM::Telemetry::Carrier
    LLM::Telemetry::Carrier{SqliteTelemetry::SPAN_KEY => span_id, SqliteTelemetry::TRACE_KEY => trace_id}
  end

  private def status(json : JSON::Any) : LLM::Telemetry::SpanStatus
    return LLM::Telemetry::SpanStatus.ok if json["status"].as_s == "ok"
    error = json["error"]?
    error ? LLM::Telemetry::SpanStatus.error(error["name"].as_s, error["message"].as_s) : LLM::Telemetry::SpanStatus.error
  end
end

class SqliteStoreFixture < Testing::StoreFixture
  getter fixture : TelemetryFixture

  def initialize(clock : LLM::Telemetry::Clock)
    @fixture = TelemetryFixture.new(clock)
  end

  def context : LLM::Telemetry::TelemetryContext
    fixture.telemetry
  end

  def store : LLM::Telemetry::TelemetryStore
    fixture.telemetry
  end

  def flush : Nil
    fixture.telemetry.flush
  end

  def close : Nil
    fixture.close
  end
end
