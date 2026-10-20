# src/llm/chord/telemetry/memory.cr
require "uuid"

module LLM::Chord::Telemetry
  record RecordedEvent, name : String, attributes : Attributes
  record RecordedLink, context : Carrier, attributes : Attributes
  record RecordedSpan, id : Int64, parent_id : Int64?, context : Carrier, parent_context : Carrier?,
    links : Array(RecordedLink), name : String, attributes : Attributes, events : Array(RecordedEvent),
    status : SpanStatus, settled : Bool, end_sequence : Int64?
  record RecordedMeasurement, kind : MetricKind, name : String, description : String?, unit : String?,
    boundaries : Array(Float64)?, value : Float64, attributes : Attributes, context : Carrier?

  def self.carrier_of(context : TelemetryContext) : Carrier?
    case context
    when InMemoryTelemetryContext::LiveSpan, InMemoryTelemetryContext::ExtractedParent
      context.carrier
    end
  end

  class InMemoryTelemetryContext < TelemetryContext
    include Metrics
    include Propagation
    include TelemetryStore

    SCOPE_KEY = "pi-memory-scope"
    SPAN_KEY  = "pi-memory-span"
    TRACE_KEY = "pi-memory-trace"

    record TimedEvent, time_ms : Float64, name : String, attributes : Attributes
    record Parent, context : Carrier, local_id : Int64?, span : SpanRecord? = nil
    record Measurement, interval_ms : Int64, measurement : RecordedMeasurement

    class SpanRecord
      property started_ms : Float64
      property clock : Time::Instant
      property ended_ms : Float64? = nil
      property id : Int64
      property parent_id : Int64?
      property context : Carrier
      property parent_context : Carrier?
      property links = [] of RecordedLink
      property name : String
      property attributes : Attributes
      property events = [] of TimedEvent
      property status = SpanStatus.ok
      property? explicit_status = false
      property? settled = false
      property end_sequence : Int64? = nil

      def initialize(@started_ms, @clock, @id, @parent_id, @context, @parent_context, @name, @attributes); end
    end

    class State
      getter scope : String = UUID.random.to_s
      getter spans = [] of SpanRecord
      getter measurements = [] of Measurement
      property next_span_id = 1_i64
      property next_end_sequence = 1_i64

      setter owner : InMemoryTelemetryContext? = nil

      def owner : InMemoryTelemetryContext
        @owner.not_nil!
      end
    end

    class LiveSpan < TelemetrySpan
      def initialize(@state : State, @record : SpanRecord); end

      def carrier : Carrier
        @record.context
      end

      def metrics : Metrics?
        @state.owner
      end

      def propagation : Propagation?
        @state.owner
      end

      def start_span(options : SpanOptions, &)
        InMemoryTelemetryContext.run(@state, Parent.new(@record.context, @record.id, @record), options) { |span| yield span }
      end

      def add_link(link : SpanLink) : Nil
        return if @record.settled?
        InMemoryTelemetryContext.copy_link(link).try { |copy| @record.links << copy }
      end

      def add_event(name : String, attributes : Attributes? = nil) : Nil
        return if @record.settled?
        elapsed = (Time.instant - @record.clock).total_milliseconds
        @record.events << TimedEvent.new(elapsed, name, Telemetry.copy_attributes(attributes))
      end

      def merge_attributes(attributes : Attributes) : Nil
        return if @record.settled?
        @record.attributes = @record.attributes.merge(Telemetry.copy_attributes(attributes))
      end

      def status=(status : SpanStatus) : Nil
        return if @record.settled?
        @record.status = status
        @record.explicit_status = true
      end
    end

    class ExtractedParent < TelemetryContext
      getter carrier : Carrier

      def initialize(@state : State, @carrier : Carrier, @local_id : Int64?); end

      def metrics : Metrics?
        @state.owner
      end

      def propagation : Propagation?
        @state.owner
      end

      def start_span(options : SpanOptions, &)
        InMemoryTelemetryContext.run(@state, Parent.new(@carrier, @local_id), options) { |span| yield span }
      end
    end

    class InertSpan < TelemetrySpan
      def initialize(@state : State); end

      def metrics : Metrics?
        @state.owner
      end

      def propagation : Propagation?
        @state.owner
      end

      def start_span(options : SpanOptions, &)
        yield InertSpan.new(@state)
      end

      def add_link(link : SpanLink) : Nil
      end

      def add_event(name : String, attributes : Attributes? = nil) : Nil
      end

      def merge_attributes(attributes : Attributes) : Nil
      end

      def status=(status : SpanStatus) : Nil
      end
    end

    class MeasurementRecorder
      @description : String?
      @unit : String?
      @boundaries : Array(Float64)?

      def initialize(@state : State, @kind : MetricKind, @name : String, options : InstrumentOptions?)
        @description = options.try(&.description)
        @unit = options.try(&.unit)
        @boundaries = @kind.histogram? ? options.try(&.boundaries).try(&.dup) : nil
      end

      def record(value : Number, attributes : Attributes?, context : TelemetryContext?) : Nil
        carrier = context.try { |target| Telemetry.carrier_of(target) }
        interval = (Time.utc.to_unix_ms // 10_000) * 10_000
        @state.measurements << Measurement.new(interval, RecordedMeasurement.new(
          @kind, @name, @description, @unit, @boundaries.try(&.dup), value.to_f64,
          Telemetry.copy_attributes(attributes), carrier.try(&.dup)))
      end
    end

    class MemoryCounter < Counter
      def initialize(@recorder : MeasurementRecorder); end

      def add(value : Number, attributes : Attributes? = nil) : Nil
        @recorder.record(value, attributes, nil)
      end
    end

    class MemoryUpDownCounter < UpDownCounter
      def initialize(@recorder : MeasurementRecorder); end

      def add(value : Number, attributes : Attributes? = nil) : Nil
        @recorder.record(value, attributes, nil)
      end
    end

    class MemoryHistogram < Histogram
      def initialize(@recorder : MeasurementRecorder); end

      def record(value : Number, attributes : Attributes? = nil, context : TelemetryContext? = nil) : Nil
        @recorder.record(value, attributes, context)
      end
    end

    @state : State

    def initialize
      @state = State.new
      @state.owner = self
    end

    def metrics : Metrics?
      self
    end

    def propagation : Propagation?
      self
    end

    def start_span(options : SpanOptions, &)
      InMemoryTelemetryContext.run(@state, nil, options) { |span| yield span }
    end

    def inject(context : TelemetryContext) : Carrier?
      Telemetry.carrier_of(context).try(&.dup)
    end

    def extract(carrier : Carrier?) : TelemetryContext
      scope = carrier.try(&.[SCOPE_KEY]?)
      span = carrier.try(&.[SPAN_KEY]?)
      trace = carrier.try(&.[TRACE_KEY]?)
      return self unless scope && span && trace
      context = Carrier{SCOPE_KEY => scope, SPAN_KEY => span, TRACE_KEY => trace}
      local_id = scope == @state.scope ? span.to_i64? : nil
      ExtractedParent.new(@state, context, local_id)
    end

    def counter(name : String, options : InstrumentOptions? = nil) : Counter
      MemoryCounter.new(MeasurementRecorder.new(@state, MetricKind::Counter, name, options))
    end

    def up_down_counter(name : String, options : InstrumentOptions? = nil) : UpDownCounter
      MemoryUpDownCounter.new(MeasurementRecorder.new(@state, MetricKind::UpDownCounter, name, options))
    end

    def histogram(name : String, options : InstrumentOptions? = nil) : Histogram
      MemoryHistogram.new(MeasurementRecorder.new(@state, MetricKind::Histogram, name, options))
    end

    def get_trace(trace_id : String) : StoredTrace?
      spans = stored_spans.select { |span| span.trace_id == trace_id }
      spans.empty? ? nil : StoredTrace.new(trace_id, spans)
    end

    def find_traces(query : TraceQuery = TraceQuery.new) : TracePage
      after = query.cursor.try { |cursor| JSON.parse(cursor).as_a }
      after_started = after.try(&.[0].as_f)
      after_trace = after.try(&.[1].as_s)
      grouped = {} of String => Array(StoredSpan)
      stored_spans.each { |span| (grouped[span.trace_id] ||= [] of StoredSpan) << span }
      matches = grouped.map { |trace_id, spans| StoredTrace.new(trace_id, spans) }.select do |trace|
        first = trace.spans[0]
        (query.name.nil? || first.name == query.name) &&
          (query.start_min.nil? || first.started_ms >= query.start_min.not_nil!) &&
          (query.start_max.nil? || first.started_ms <= query.start_max.not_nil!) &&
          (after_started.nil? || first.started_ms < after_started ||
            (first.started_ms == after_started && trace.trace_id > after_trace.not_nil!)) &&
          (!query.errors || trace.spans.any?(&.status.error?)) &&
          (query.attributes.nil? || trace.spans.any? { |span| attributes_match?(span.attributes, query.attributes.not_nil!) })
      end
      matches.sort! do |left, right|
        compared = right.spans[0].started_ms <=> left.spans[0].started_ms
        compared == 0 ? left.trace_id <=> right.trace_id : compared
      end
      traces = matches.first(query.limit)
      cursor = if matches.size > query.limit
                 last = traces[-1]
                 [JSON::Any.new(last.spans[0].started_ms), JSON::Any.new(last.trace_id)].to_json
               end
      TracePage.new(traces, cursor)
    end

    def find_metrics(query : MetricQuery) : Array(StoredMetric)
      @state.measurements.compact_map do |entry|
        measurement = entry.measurement
        next unless measurement.name == query.name
        next if (minimum = query.start_min) && entry.interval_ms < minimum
        next if (maximum = query.start_max) && entry.interval_ms > maximum
        next if (attributes = query.attributes) && !attributes_match?(measurement.attributes, attributes)
        StoredMetric.new(entry.interval_ms, measurement.name, measurement.kind, measurement.unit,
          Telemetry.copy_attributes(measurement.attributes), 1_i64, measurement.value, measurement.value, measurement.value)
      end
    end

    def recorded_metrics : Array(RecordedMeasurement)
      @state.measurements.map do |entry|
        measurement = entry.measurement
        measurement.copy_with(
          boundaries: measurement.boundaries.try(&.dup),
          attributes: Telemetry.copy_attributes(measurement.attributes),
          context: measurement.context.try(&.dup))
      end
    end

    def recorded_spans : Array(RecordedSpan)
      @state.spans.map do |span|
        RecordedSpan.new(span.id, span.parent_id, span.context.dup, span.parent_context.try(&.dup),
          span.links.map { |link| RecordedLink.new(link.context.dup, Telemetry.copy_attributes(link.attributes)) },
          span.name, Telemetry.copy_attributes(span.attributes),
          span.events.map { |event| RecordedEvent.new(event.name, Telemetry.copy_attributes(event.attributes)) },
          span.status, span.settled?, span.end_sequence)
      end
    end

    def self.run(state : State, parent : Parent?, options : SpanOptions, &)
      if parent && (parent_span = parent.span) && parent_span.settled?
        return yield InertSpan.new(state)
      end
      entry = create_span(state, parent, options)
      state.spans << entry
      begin
        yield LiveSpan.new(state, entry)
      rescue error
        entry.status = SpanStatus.error(error.class.name, error.message || "") unless entry.explicit_status?
        raise error
      ensure
        entry.settled = true
        entry.ended_ms = entry.started_ms + (Time.instant - entry.clock).total_milliseconds
        entry.end_sequence = state.next_end_sequence
        state.next_end_sequence += 1
      end
    end

    def self.copy_link(link : SpanLink) : RecordedLink?
      Telemetry.carrier_of(link.context).try { |carrier| RecordedLink.new(carrier.dup, Telemetry.copy_attributes(link.attributes)) }
    end

    private def self.create_span(state : State, parent : Parent?, options : SpanOptions) : SpanRecord
      links = [] of RecordedLink
      options.links.try &.each { |link| copy_link(link).try { |copy| links << copy } }
      id = state.next_span_id
      state.next_span_id += 1
      trace = parent.try(&.context[TRACE_KEY]?) || "#{state.scope}:#{id}"
      context = {SCOPE_KEY => state.scope, SPAN_KEY => id.to_s, TRACE_KEY => trace}
      entry = SpanRecord.new(Time.utc.to_unix_ms.to_f64, Time.instant, id, parent.try(&.local_id), context,
        parent.try(&.context.dup), options.name, Telemetry.copy_attributes(options.attributes))
      entry.links = links
      entry
    end

    private def stored_spans : Array(StoredSpan)
      spans = @state.spans.select(&.settled?).map do |span|
        StoredSpan.new(
          carrier_id(span.context), span.context[TRACE_KEY], span.parent_context.try { |parent| carrier_id(parent) },
          span.name, span.started_ms, span.ended_ms.not_nil!, Telemetry.copy_attributes(span.attributes),
          span.events.map { |event| StoredEvent.new(event.name, event.time_ms, Telemetry.copy_attributes(event.attributes)) },
          span.links.map { |link| StoredLink.new(link.context[TRACE_KEY], carrier_id(link.context), Telemetry.copy_attributes(link.attributes)) },
          span.status)
      end
      spans.sort! do |left, right|
        compared = left.started_ms <=> right.started_ms
        compared == 0 ? left.id <=> right.id : compared
      end
    end

    private def carrier_id(carrier : Carrier) : String
      "#{carrier[SCOPE_KEY]?}:#{carrier[SPAN_KEY]?}"
    end

    private def attributes_match?(attributes : Attributes, expected : Hash(String, QueryValue)) : Bool
      expected.all? { |key, value| attributes[key]? == value }
    end
  end
end
