# spec/telemetry_sqlite_store_spec.cr
require "./support/telemetry_sqlite"

describe "SQLite telemetry store conformance" do
  factory = ->(clock : ManualClock) { SqliteStoreFixture.new(clock).as(Testing::StoreFixture) }
  Testing.store_conformance(factory).each do |test|
    it(test.name) { test.run }
  end
end

describe "SQLite telemetry reads" do
  it "uses two span queries for a page, not one query per trace" do
    with_telemetry do |fixture|
      25.times { fixture.telemetry.start_span(span_options("root")) { } }
      fixture.telemetry.flush
      fixture.db.queries = 0
      fixture.telemetry.find_traces(LLM::Telemetry::TraceQuery.new(limit: 20)).traces.size.should eq 20
      fixture.db.queries.should eq 2
      fixture.db.queries = 0
      fixture.telemetry.find_traces(LLM::Telemetry::TraceQuery.new(limit: 1)).traces.size.should eq 1
      fixture.db.queries.should eq 2
    end
  end

  it "reads committed rows without implicitly flushing, including after close" do
    with_telemetry do |fixture|
      fixture.telemetry.start_span(span_options("pending")) { }
      fixture.telemetry.find_traces.traces.should be_empty
      fixture.telemetry.counter("partial").add(2)
      fixture.telemetry.find_metrics(LLM::Telemetry::MetricQuery.new("partial")).should be_empty
      fixture.telemetry.close
      trace = fixture.telemetry.find_traces.traces[0]
      fixture.telemetry.get_trace(trace.trace_id).not_nil!.spans[0].name.should eq "pending"
      metrics = fixture.telemetry.find_metrics(LLM::Telemetry::MetricQuery.new("partial"))
      metrics.map { |metric| {metric.count, metric.sum} }.should eq [{1_i64, 2.0}]
    end
  end

  it "keeps surviving descendants discoverable after a stored parent is removed" do
    with_telemetry do |fixture|
      fixture.telemetry.start_span(span_options("root")) { |root| root.start_span(span_options("child")) { } }
      fixture.telemetry.flush
      original = fixture.telemetry.find_traces.traces[0]
      parent = original.spans.find!(&.name.==("root"))
      fixture.db.run("DELETE FROM telemetry_spans WHERE id = ?", parent.id)
      trace = fixture.telemetry.find_traces.traces[0]
      trace.trace_id.should eq original.trace_id
      trace.spans.size.should eq 1
      trace.spans[0].name.should eq "child"
      trace.spans[0].parent_id.should eq parent.id
      fixture.telemetry.get_trace(original.trace_id).not_nil!.spans.size.should eq 1
    end
  end

  it "reads attributes, events, links and statuses back as recorded" do
    with_telemetry do |fixture|
      target = fixture.telemetry.start_span(span_options("target")) { |span| span }
      attributes = LLM::Telemetry::Attributes{"flag" => false, "count" => 3_i64, "ratio" => 0.5, "names" => ["a", "b"],
                                              "ids" => [1_i64, 2_i64], "scores" => [1.5, 2.0], "checks" => [true]}
      links = [LLM::Telemetry::SpanLink.new(target, LLM::Telemetry.attributes(reason: "cause"))]
      fixture.telemetry.start_span(span_options("source", attributes, links)) do |span|
        span.add_event("checked", LLM::Telemetry.attributes(step: 2))
        span.status = LLM::Telemetry::SpanStatus.error("Expected", "boom")
      end
      fixture.telemetry.flush
      trace = fixture.telemetry.find_traces(LLM::Telemetry::TraceQuery.new(name: "source")).traces[0]
      span = trace.spans[0]
      span.attributes.should eq attributes
      span.events.map(&.name).should eq ["checked"]
      span.events[0].attributes.should eq LLM::Telemetry.attributes(step: 2)
      target_span = fixture.telemetry.find_traces(LLM::Telemetry::TraceQuery.new(name: "target")).traces[0].spans[0]
      span.links.should eq [LLM::Telemetry::StoredLink.new(target_span.trace_id, target_span.id, LLM::Telemetry.attributes(reason: "cause"))]
      span.status.should eq LLM::Telemetry::SpanStatus.error("Expected", "boom")
      fixture.telemetry.find_traces(LLM::Telemetry::TraceQuery.new(attributes: {"flag" => false.as(LLM::Telemetry::QueryValue)})).traces.size.should eq 1
      fixture.telemetry.find_traces(LLM::Telemetry::TraceQuery.new(attributes: {"ratio" => 0.5.as(LLM::Telemetry::QueryValue)})).traces.size.should eq 1
    end
  end

  it "distinguishes boolean true from numeric 1 and text in attribute filters" do
    with_telemetry do |fixture|
      fixture.telemetry.start_span(span_options("numeric", LLM::Telemetry.attributes(flag: 1))) { }
      fixture.telemetry.start_span(span_options("boolean", LLM::Telemetry.attributes(flag: true))) { }
      fixture.telemetry.start_span(span_options("text", LLM::Telemetry.attributes(flag: "1"))) { }
      fixture.telemetry.counter("flags").add(1, LLM::Telemetry.attributes(flag: 1))
      fixture.telemetry.counter("flags").add(2, LLM::Telemetry.attributes(flag: true))
      fixture.telemetry.close
      names = ->(value : LLM::Telemetry::QueryValue) do
        fixture.telemetry.find_traces(LLM::Telemetry::TraceQuery.new(attributes: {"flag" => value})).traces.map(&.spans[0].name)
      end
      names.call(true).should eq ["boolean"]
      names.call(1_i64).should eq ["numeric"]
      names.call("1").should eq ["text"]
      names.call(false).should be_empty
      sums = fixture.telemetry.find_metrics(LLM::Telemetry::MetricQuery.new("flags", attributes: {"flag" => true.as(LLM::Telemetry::QueryValue)})).map(&.sum)
      sums.should eq [2.0]
    end
  end
end
