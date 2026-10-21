# spec/telemetry_sqlite_spec.cr
require "./support/telemetry_sqlite"

describe "SQLite telemetry span and propagation conformance" do
  factory = -> { SqliteAdapterFixture.new.as(Testing::AdapterFixture) }
  Testing.adapter_conformance(factory).reject(&.group.==("metrics")).each do |test|
    it("#{test.group}: #{test.name}") { test.run }
  end
end

describe "SQLite telemetry buffering and aggregation" do
  it "does not execute SQL while recording and stores only settled spans" do
    with_telemetry do |fixture|
      gate = Gate.new
      done = Channel(Nil).new(1)
      active = nil.as(LLM::Telemetry::TelemetrySpan?)
      spawn do
        fixture.telemetry.start_span(span_options("active")) do |span|
          active = span
          span.add_event("begin")
          fixture.telemetry.counter("calls").add(1)
          gate.wait
        end
      ensure
        done.send(nil)
      end
      Fiber.yield
      fixture.db.transactions.should eq 0
      fixture.telemetry.flush
      fixture.db.all("SELECT * FROM telemetry_spans").should be_empty
      gate.open
      done.receive
      fixture.db.transactions.should eq 1
      active.not_nil!.add_event("late")
      fixture.telemetry.flush
      row = fixture.db.get("SELECT * FROM telemetry_spans").not_nil!
      row["ended_ms"].as(Float64).should be >= row["started_ms"].as(Float64)
      events = JSON.parse(row["events"].as(String)).as_a
      events.map(&.["name"].as_s).should eq ["begin"]
      events[0]["time_ms"].raw.should be_a(Int64 | Float64)
      events[0]["attributes"].should eq JSON.parse("{}")
    end
  end

  it "aggregates canonical series by interval and writes partial intervals only on close" do
    clock = ManualClock.new(20_001_i64)
    with_telemetry(clock) do |fixture|
      metric = fixture.telemetry.histogram("duration", LLM::Telemetry::InstrumentOptions.new(unit: "ms", boundaries: [1.0, 10.0]))
      tags = ["original"]
      metric.record(2, LLM::Telemetry::Attributes{"b" => tags, "a" => true})
      tags << "changed"
      metric.record(8, LLM::Telemetry.attributes(a: true, b: ["original"]))
      fixture.telemetry.up_down_counter("active").add(-1)
      fixture.telemetry.flush
      fixture.db.all("SELECT * FROM telemetry_metrics").should be_empty
      clock.now_ms = 30_001
      metric.record(4, LLM::Telemetry::Attributes{"b" => ["original"], "a" => true})
      fixture.telemetry.flush
      rows = fixture.db.all("SELECT * FROM telemetry_metrics ORDER BY name")
      rows.size.should eq 2
      pick(rows[0], "name", "kind", "unit", "count", "sum", "min", "max").should eq({
        "name" => "active", "kind" => "upDownCounter", "unit" => nil, "count" => 1, "sum" => -1.0, "min" => -1.0, "max" => -1.0,
      })
      pick(rows[1], "interval_ms", "name", "kind", "unit", "attributes", "count", "sum", "min", "max").should eq({
        "interval_ms" => 20_000, "name" => "duration", "kind" => "histogram", "unit" => "ms",
        "attributes" => %({"a":true,"b":["original"]}), "count" => 2, "sum" => 10.0, "min" => 2.0, "max" => 8.0,
      })
      rows[1]["series_key"].should eq %(["duration","histogram","ms","{\\"a\\":true,\\"b\\":[\\"original\\"]}"])
      fixture.telemetry.close
      fixture.db.get("SELECT count, sum FROM telemetry_metrics WHERE interval_ms = 30000").should eq({"count" => 1, "sum" => 4.0})
    end
  end

  it "separates kind, name, unit, and caller attributes without retaining descriptions or boundaries" do
    with_telemetry do |fixture|
      fixture.telemetry.counter("same").add(1)
      fixture.telemetry.counter("same", LLM::Telemetry::InstrumentOptions.new(unit: "By")).add(2)
      fixture.telemetry.up_down_counter("same").add(3)
      fixture.telemetry.counter("other").add(4)
      fixture.telemetry.counter("same").add(5, LLM::Telemetry.attributes(method: "read"))
      fixture.telemetry.histogram("same", LLM::Telemetry::InstrumentOptions.new(description: "first", boundaries: [1.0])).record(6)
      fixture.telemetry.histogram("same", LLM::Telemetry::InstrumentOptions.new(description: "second", boundaries: [2.0])).record(7)
      fixture.telemetry.close
      rows = fixture.db.all("SELECT * FROM telemetry_metrics")
      rows.size.should eq 6
      pick(rows.find!(&.["kind"].==("histogram")), "count", "sum", "min", "max").should eq({"count" => 2, "sum" => 13.0, "min" => 6.0, "max" => 7.0})
    end
  end

  it "strictly bounds queued spans including the in-flight batch and bounds pending metric series" do
    with_telemetry(max_queued_spans: 1) do |fixture|
      fixture.telemetry.start_span(span_options("first")) { }
      fixture.telemetry.counter("first").add(1)
      fixture.telemetry.counter("first").add(2)
      fixture.telemetry.counter("overflow").add(3)
      entered = Gate.new
      release = Gate.new
      fixture.db.before_transaction = -> { entered.open; release.wait }
      flushing = Future(Nil).run { fixture.telemetry.flush }
      entered.wait
      fixture.telemetry.start_span(span_options("overflow")) { }
      fixture.telemetry.dropped_spans.should eq 1
      fixture.telemetry.dropped_measurements.should eq 1
      release.open
      flushing.wait
      fixture.telemetry.start_span(span_options("after")) { }
      fixture.telemetry.close
      fixture.db.all("SELECT name FROM telemetry_spans ORDER BY rowid").should eq [{"name" => "first"}, {"name" => "after"}]
      fixture.db.all("SELECT name, count, sum FROM telemetry_metrics").should eq [{"name" => "first", "count" => 2, "sum" => 3.0}]
    end
  end

  it "counts in-flight metric intervals against capacity until commit" do
    clock = ManualClock.new(20_001_i64)
    with_telemetry(clock, max_queued_spans: 1) do |fixture|
      fixture.telemetry.counter("calls").add(1)
      clock.now_ms = 30_001
      entered = Gate.new
      release = Gate.new
      fixture.db.before_transaction = -> { entered.open; release.wait }
      flushing = Future(Nil).run { fixture.telemetry.flush }
      entered.wait
      fixture.telemetry.counter("calls").add(2)
      fixture.telemetry.dropped_measurements.should eq 1
      release.open
      flushing.wait
      fixture.telemetry.counter("calls").add(3)
      fixture.telemetry.close
      fixture.db.all("SELECT interval_ms, sum FROM telemetry_metrics ORDER BY interval_ms").should eq [
        {"interval_ms" => 20_000, "sum" => 1.0}, {"interval_ms" => 30_000, "sum" => 3.0},
      ]
    end
  end

  it "flushes once per second and retains only rows inside the retention window" do
    clock = ManualClock.new(20_001_i64)
    with_telemetry(clock, retention: 20.seconds) do |fixture|
      fixture.telemetry.start_span(span_options("old")) { }
      fixture.telemetry.counter("old").add(1)
      clock.advance(1_000)
      fixture.db.all("SELECT name FROM telemetry_spans").should eq [{"name" => "old"}]
      clock.now_ms = 50_001
      fixture.telemetry.start_span(span_options("recent")) { }
      fixture.telemetry.counter("recent").add(1)
      clock.advance(1_000)
      fixture.db.all("SELECT name FROM telemetry_spans").should eq [{"name" => "recent"}]
      fixture.db.all("SELECT name FROM telemetry_metrics").should be_empty
      fixture.telemetry.close
      fixture.db.all("SELECT name FROM telemetry_metrics").should eq [{"name" => "recent"}]
    end
  end

  it "flushes on the system clock's one-second timer" do
    with_telemetry do |fixture|
      fixture.telemetry.start_span(span_options("timed")) { }
      eventually(3.seconds) { !fixture.db.all("SELECT name FROM telemetry_spans").empty? }
    end
  end

  it "serializes concurrent flush and close without losing measurements recorded during writes" do
    clock = ManualClock.new(20_001_i64)
    with_telemetry(clock) do |fixture|
      fixture.telemetry.counter("calls").add(1)
      clock.now_ms = 30_001
      entered = Gate.new
      release = Gate.new
      fixture.db.before_transaction = -> { entered.open; release.wait }
      first = Future(Nil).run { fixture.telemetry.flush }
      entered.wait
      fixture.telemetry.counter("calls").add(2)
      second = Future(Nil).run { fixture.telemetry.flush }
      close = Future(Nil).run { fixture.telemetry.close }
      again = Future(Nil).run { fixture.telemetry.close }
      release.open
      [first, second, close, again].each(&.wait)
      fixture.db.maximum_active.should eq 1
      fixture.db.all("SELECT interval_ms, sum FROM telemetry_metrics ORDER BY interval_ms").should eq [
        {"interval_ms" => 20_000, "sum" => 1.0}, {"interval_ms" => 30_000, "sum" => 2.0},
      ]
    end
  end

  it "close does not wait for active business callbacks, ignores late completions, and leaves the database open" do
    with_telemetry do |fixture|
      release = Gate.new
      done = Channel(Nil).new(1)
      active = nil.as(LLM::Telemetry::TelemetrySpan?)
      spawn do
        fixture.telemetry.start_span(span_options("active")) do |span|
          active = span
          release.wait
        end
      ensure
        done.send(nil)
      end
      Fiber.yield
      fixture.telemetry.start_span(span_options("settled")) { }
      fixture.telemetry.close
      fixture.db.all("SELECT name FROM telemetry_spans").should eq [{"name" => "settled"}]
      span = active.not_nil!
      span.add_event("late")
      span.start_span(span_options("late-child")) { }
      fixture.telemetry.counter("late").add(1)
      release.open
      done.receive
      fixture.telemetry.flush
      fixture.db.all("SELECT name FROM telemetry_spans").should eq [{"name" => "settled"}]
      fixture.db.all("SELECT * FROM telemetry_metrics").should be_empty
    end
  end

  it "stops permanently after a write failure and reports the identical error without retry" do
    with_telemetry do |fixture|
      fixture.telemetry.start_span(span_options("queued")) { }
      error = Exception.new("write failure")
      fixture.db.failure = error
      expect_raises(Exception, "write failure") { fixture.telemetry.flush }.should be error
      fixture.telemetry.start_span(span_options("ignored")) { 1 }.should eq 1
      fixture.telemetry.counter("ignored").add(1)
      expect_raises(Exception, "write failure") { fixture.telemetry.flush }.should be error
      close = Future(Nil).run { fixture.telemetry.close }
      again = Future(Nil).run { fixture.telemetry.close }
      expect_raises(Exception, "write failure") { close.wait }.should be error
      expect_raises(Exception, "write failure") { again.wait }.should be error
      fixture.db.transactions.should eq 1
      fixture.db.failure = nil
      fixture.db.all("SELECT * FROM telemetry_spans").should be_empty
    end
  end

  it "remembers a background write failure and stops its timer" do
    clock = ManualClock.new(20_001_i64)
    with_telemetry(clock) do |fixture|
      error = Exception.new("background failure")
      fixture.db.failure = error
      clock.advance(1_000)
      expect_raises(Exception, "background failure") { fixture.telemetry.flush }.should be error
      expect_raises(Exception, "background failure") { fixture.telemetry.close }.should be error
      clock.timers.should eq 0
      clock.advance(5_000)
      fixture.db.transactions.should eq 1
    end
  end

  it "rolls back spans and metric aggregates together on SQL failure" do
    with_telemetry do |fixture|
      fixture.telemetry.start_span(span_options("rollback")) { }
      fixture.telemetry.counter("rollback").add(1)
      fixture.db.exec("DROP TABLE telemetry_metrics")
      expect_raises(SQLite3::Exception) { fixture.telemetry.close }
      fixture.db.all("SELECT * FROM telemetry_spans").should be_empty
    end
  end

  it "reuses migrations, preserves identities across reopen, and merges aggregates from multiple adapters" do
    clock = ManualClock.new(20_001_i64)
    db = Sqlite.open_database(":memory:")
    begin
      first = LLM::Chord.create_sqlite_telemetry(db, clock: clock)
      carrier = first.start_span(span_options("parent")) { |span| first.inject(span) }
      first.counter("shared").add(2)
      first.close
      second = LLM::Chord.create_sqlite_telemetry(db, clock: clock)
      second.extract(carrier).start_span(span_options("child")) { }
      second.counter("shared").add(4)
      second.close
      rows = db.all("SELECT * FROM telemetry_spans ORDER BY rowid")
      rows[1]["parent_id"].should eq rows[0]["id"]
      rows[1]["trace_id"].should eq rows[0]["trace_id"]
      rows[0]["trace_id"].should eq rows[0]["id"]
      rows[1]["id"].should_not eq rows[0]["id"]
      db.all("SELECT count, sum, min, max FROM telemetry_metrics").should eq [{"count" => 2, "sum" => 6.0, "min" => 2.0, "max" => 4.0}]
    ensure
      db.close
    end
  end

  it "writes span JSON as JSON.stringify does, so Node and Crystal recorders can share a database" do
    clock = ManualClock.new(20_000_i64)
    with_telemetry(clock) do |fixture|
      target = fixture.telemetry.start_span(span_options("target")) { |span| span }
      links = [LLM::Telemetry::SpanLink.new(target)]
      fixture.telemetry.start_span(span_options("written", LLM::Telemetry::Attributes{"ratio" => 2.0, "label" => %(a"b), "tags" => ["x"]}, links)) do |span|
        span.add_event("step", LLM::Telemetry.attributes(n: 1))
        span.status = LLM::Telemetry::SpanStatus.error("Expected", "failed")
      end
      fixture.telemetry.flush
      row = fixture.db.get("SELECT * FROM telemetry_spans WHERE name = 'written'").not_nil!
      row["started_ms"].should eq 20_000.0
      row["attributes"].should eq %({"ratio":2,"label":"a\\"b","tags":["x"]})
      row["events"].should eq %([{"name":"step","time_ms":0,"attributes":{"n":1}}])
      row["links"].as(String).should match(/\A\[\{"trace_id":"[^"]+","span_id":"[^"]+","attributes":\{\}\}\]\z/)
      row["status"].should eq %({"status":"error","error":{"name":"Expected","message":"failed"}})
    end
  end
end
