# src/llm/chord/telemetry_sqlite/recorder.cr
module LLM::Chord
  class SqliteTelemetry < LLM::Telemetry::TelemetryContext
    include LLM::Telemetry::Metrics
    include LLM::Telemetry::Propagation
    include LLM::Telemetry::TelemetryStore

    SPAN_KEY                 = "pi-sqlite-span"
    TRACE_KEY                = "pi-sqlite-trace"
    INTERVAL_MS              = 10_000_i64
    FLUSH_INTERVAL           = 1.second
    DEFAULT_RETENTION        = 7.days
    DEFAULT_MAX_QUEUED_SPANS = 10_000

    SPANS_TABLE = <<-SQL
      CREATE TABLE telemetry_spans (id TEXT PRIMARY KEY, trace_id TEXT NOT NULL, parent_id TEXT, name TEXT, started_ms REAL,
      ended_ms REAL NOT NULL, attributes TEXT, events TEXT, links TEXT, status TEXT)
      SQL

    METRICS_TABLE = <<-SQL
      CREATE TABLE telemetry_metrics (interval_ms INTEGER, series_key TEXT, name TEXT, kind TEXT,
      unit TEXT, attributes TEXT, count INTEGER, sum REAL, min REAL, max REAL, PRIMARY KEY(interval_ms, series_key))
      SQL

    MIGRATIONS = [
      Sqlite::Migration.new(1, [
        SPANS_TABLE,
        "CREATE INDEX telemetry_spans_ended_ms ON telemetry_spans(ended_ms)",
        "CREATE INDEX telemetry_spans_trace_started ON telemetry_spans(trace_id, started_ms)",
        "CREATE INDEX telemetry_spans_started_ms ON telemetry_spans(started_ms)",
        METRICS_TABLE,
      ]),
    ]

    INSERT_SPAN   = "INSERT INTO telemetry_spans VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"
    INSERT_METRIC = <<-SQL
      INSERT INTO telemetry_metrics VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(interval_ms, series_key) DO UPDATE SET count = count + excluded.count,
      sum = sum + excluded.sum, min = min(min, excluded.min), max = max(max, excluded.max)
      SQL

    alias TraceQuery = LLM::Telemetry::TraceQuery

    record Identity, id : String, trace_id : String

    OK_STATUS = JSON::Any.new({"status" => JSON::Any.new("ok")})

    class Metric
      getter interval : Int64
      getter key : String
      getter name : String
      getter kind : LLM::Telemetry::MetricKind
      getter unit : String?
      getter attributes : String
      property count : Int64 = 0_i64
      property sum : Float64 = 0.0
      property min : Float64 = Float64::INFINITY
      property max : Float64 = -Float64::INFINITY

      def initialize(@interval, @key, @name, @kind, @unit, @attributes); end

      def add(value : Float64) : Nil
        @count += 1
        @sum += value
        @min = Math.min(@min, value)
        @max = Math.max(@max, value)
      end

      def values : Array(Sqlite::Value)
        [@interval, @key, @name, @kind.label, @unit, @attributes, @count, @sum, @min, @max] of Sqlite::Value
      end
    end

    class Instrument
      def initialize(@recorder : SqliteTelemetry, @kind : LLM::Telemetry::MetricKind, @name : String, @unit : String?); end

      def measure(value : Number, attributes : LLM::Telemetry::Attributes?) : Nil
        @recorder.measure(@kind, @name, @unit, value.to_f64, attributes)
      end
    end

    class SqliteCounter < LLM::Telemetry::Counter
      def initialize(@instrument : Instrument); end

      def add(value : Number, attributes : LLM::Telemetry::Attributes? = nil) : Nil
        @instrument.measure(value, attributes)
      end
    end

    class SqliteUpDownCounter < LLM::Telemetry::UpDownCounter
      def initialize(@instrument : Instrument); end

      def add(value : Number, attributes : LLM::Telemetry::Attributes? = nil) : Nil
        @instrument.measure(value, attributes)
      end
    end

    class SqliteHistogram < LLM::Telemetry::Histogram
      def initialize(@instrument : Instrument); end

      def record(value : Number, attributes : LLM::Telemetry::Attributes? = nil, context : LLM::Telemetry::TelemetryContext? = nil) : Nil
        @instrument.measure(value, attributes)
      end
    end

    class LiveSpan < LLM::Telemetry::TelemetrySpan
      getter identity : Identity
      getter? settled = false
      getter status : JSON::Any = OK_STATUS
      getter? explicit_status = false
      getter attributes : LLM::Telemetry::Attributes
      getter events = [] of JSON::Any
      getter links : Array(JSON::Any)

      getter opened : Float64

      def initialize(@recorder : SqliteTelemetry, @identity : Identity, @attributes, @links, @opened : Float64); end

      def metrics : LLM::Telemetry::Metrics?
        @recorder
      end

      def propagation : LLM::Telemetry::Propagation?
        @recorder
      end

      def start_span(options : LLM::Telemetry::SpanOptions, &)
        if @settled
          @recorder.inert(options) { |span| yield span }
        else
          @recorder.start(@identity, options) { |span| yield span }
        end
      end

      def add_link(link : LLM::Telemetry::SpanLink) : Nil
        return unless recording?
        SqliteTelemetry.link_json(link).try { |copied| @links << copied }
      end

      def add_event(name : String, attributes : LLM::Telemetry::Attributes? = nil) : Nil
        return unless recording?
        @events << JSON::Any.new({
          "name"       => JSON::Any.new(name),
          "time_ms"    => JSON::Any.new(@recorder.elapsed_ms - @opened),
          "attributes" => SqliteTelemetry.attributes_json(attributes),
        })
      end

      def merge_attributes(attributes : LLM::Telemetry::Attributes) : Nil
        return unless recording?
        @attributes = @attributes.merge(LLM::Telemetry.copy_attributes(attributes))
      end

      def status=(status : LLM::Telemetry::SpanStatus) : Nil
        return unless recording?
        @status = SqliteTelemetry.status_json(status)
        @explicit_status = true
      end

      protected def fail(error : Exception) : Nil
        return if @explicit_status
        @status = SqliteTelemetry.status_json(LLM::Telemetry::SpanStatus.error(error.class.name, error.message || ""))
      end

      protected def settle : Nil
        @settled = true
      end

      private def recording? : Bool
        !@settled && !@recorder.stopped?
      end
    end

    class ExtractedParent < LLM::Telemetry::TelemetryContext
      getter identity : Identity

      def initialize(@recorder : SqliteTelemetry, @identity : Identity); end

      def metrics : LLM::Telemetry::Metrics?
        @recorder
      end

      def propagation : LLM::Telemetry::Propagation?
        @recorder
      end

      def start_span(options : LLM::Telemetry::SpanOptions, &)
        @recorder.start(@identity, options) { |span| yield span }
      end
    end

    class InertSpan < LLM::Telemetry::TelemetrySpan
      def initialize(@recorder : SqliteTelemetry); end

      def metrics : LLM::Telemetry::Metrics?
        @recorder
      end

      def propagation : LLM::Telemetry::Propagation?
        @recorder
      end

      def start_span(options : LLM::Telemetry::SpanOptions, &)
        @recorder.inert(options) { |span| yield span }
      end

      def add_link(link : LLM::Telemetry::SpanLink) : Nil
      end

      def add_event(name : String, attributes : LLM::Telemetry::Attributes? = nil) : Nil
      end

      def merge_attributes(attributes : LLM::Telemetry::Attributes) : Nil
      end

      def status=(status : LLM::Telemetry::SpanStatus) : Nil
      end
    end

    getter dropped_spans = 0_i64
    getter dropped_measurements = 0_i64
    getter? stopped = false
    @scope = UUID.random.to_s
    @sequence = 0_i64
    @spans = [] of Array(Sqlite::Value)
    @measurements = {} of String => Metric
    @in_flight_measurements = 0
    @failed = false
    @failure : Exception? = nil
    @writing : Future(Nil)? = nil
    @closing : Future(Nil)? = nil
    @stop_timer : Proc(Nil)

    def initialize(@db : Sqlite::Database, @retention : Time::Span, @capacity : Int32, @clock : LLM::Telemetry::Clock)
      @stop_timer = @clock.every(FLUSH_INTERVAL) { tick }
    end

    def metrics : LLM::Telemetry::Metrics?
      self
    end

    def propagation : LLM::Telemetry::Propagation?
      self
    end

    def start_span(options : LLM::Telemetry::SpanOptions, &)
      start(nil, options) { |span| yield span }
    end

    def counter(name : String, options : LLM::Telemetry::InstrumentOptions? = nil) : LLM::Telemetry::Counter
      SqliteCounter.new(instrument(LLM::Telemetry::MetricKind::Counter, name, options))
    end

    def up_down_counter(name : String, options : LLM::Telemetry::InstrumentOptions? = nil) : LLM::Telemetry::UpDownCounter
      SqliteUpDownCounter.new(instrument(LLM::Telemetry::MetricKind::UpDownCounter, name, options))
    end

    def histogram(name : String, options : LLM::Telemetry::InstrumentOptions? = nil) : LLM::Telemetry::Histogram
      SqliteHistogram.new(instrument(LLM::Telemetry::MetricKind::Histogram, name, options))
    end

    def inject(context : LLM::Telemetry::TelemetryContext) : LLM::Telemetry::Carrier?
      SqliteTelemetry.identity_of(context).try do |identity|
        LLM::Telemetry::Carrier{SPAN_KEY => identity.id, TRACE_KEY => identity.trace_id}
      end
    end

    def extract(carrier : LLM::Telemetry::Carrier?) : LLM::Telemetry::TelemetryContext
      id = carrier.try(&.[SPAN_KEY]?)
      trace_id = carrier.try(&.[TRACE_KEY]?)
      return self unless id && trace_id
      ExtractedParent.new(self, Identity.new(id, trace_id))
    end

    def get_trace(trace_id : String) : LLM::Telemetry::StoredTrace?
      SqliteTelemetry.get_trace(@db, trace_id)
    end

    def find_traces(query : TraceQuery = TraceQuery.new) : LLM::Telemetry::TracePage
      SqliteTelemetry.find_traces(@db, query)
    end

    def find_metrics(query : LLM::Telemetry::MetricQuery) : Array(LLM::Telemetry::StoredMetric)
      SqliteTelemetry.find_metrics(@db, query)
    end

    def flush : Nil
      if closing = @closing
        closing.wait
      else
        drain(false)
      end
    end

    def close : Nil
      closing = @closing
      unless closing
        @stopped = true
        @stop_timer.call
        closing = @closing = Future(Nil).new
        begin
          drain(true)
          closing.resolve(nil)
        rescue error
          closing.reject(error)
        end
      end
      closing.wait
    end

    protected def elapsed_ms : Float64
      @clock.elapsed_ms
    end

    protected def start(parent : Identity?, options : LLM::Telemetry::SpanOptions, &)
      return inert(options) { |span| yield span } if @stopped
      links = [] of JSON::Any
      options.links.try &.each { |link| SqliteTelemetry.link_json(link).try { |copied| links << copied } }
      @sequence += 1
      id = "#{@scope}:#{@sequence}"
      identity = Identity.new(id, parent.try(&.trace_id) || id)
      started = @clock.now_ms.to_f64
      span = LiveSpan.new(self, identity, LLM::Telemetry.copy_attributes(options.attributes), links, @clock.elapsed_ms)
      begin
        yield span
      rescue error
        span.fail(error)
        raise error
      ensure
        span.settle
        enqueue(span, parent, options.name, started)
      end
    end

    protected def inert(options : LLM::Telemetry::SpanOptions, &)
      yield InertSpan.new(self)
    end

    protected def measure(kind : LLM::Telemetry::MetricKind, name : String, unit : String?, value : Float64,
                          attributes : LLM::Telemetry::Attributes?) : Nil
      return if @stopped
      encoded = Schema.canonical_json(SqliteTelemetry.attributes_json(attributes))
      key = Schema.stringify(JSON::Any.new([JSON::Any.new(name), JSON::Any.new(kind.label), JSON::Any.new(unit), JSON::Any.new(encoded)]))
      interval = interval_of(@clock.now_ms)
      pending_key = "#{interval}:#{key}"
      metric = @measurements[pending_key]?
      unless metric
        if @measurements.size + @in_flight_measurements >= @capacity
          @dropped_measurements += 1
          return
        end
        metric = @measurements[pending_key] = Metric.new(interval, key, name, kind, unit, encoded)
      end
      metric.add(value)
    end

    private def instrument(kind : LLM::Telemetry::MetricKind, name : String, options : LLM::Telemetry::InstrumentOptions?) : Instrument
      Instrument.new(self, kind, name, options.try(&.unit))
    end

    private def enqueue(span : LiveSpan, parent : Identity?, name : String, started : Float64) : Nil
      return if @stopped
      if @spans.size >= @capacity
        @dropped_spans += 1
        return
      end
      ended = started + @clock.elapsed_ms - span.opened
      @spans << [
        span.identity.id, span.identity.trace_id, parent.try(&.id), name, started, ended,
        Schema.stringify(JSON::Any.new(SqliteTelemetry.attributes_hash(span.attributes))),
        Schema.stringify(JSON::Any.new(span.events)),
        Schema.stringify(JSON::Any.new(span.links)),
        Schema.stringify(span.status),
      ] of Sqlite::Value
    end

    private def interval_of(now_ms : Int64) : Int64
      (now_ms // INTERVAL_MS) * INTERVAL_MS
    end

    private def tick : Nil
      flush unless @writing
    rescue
    end

    private def drain(partial : Bool) : Nil
      while writing = @writing
        writing.await_settled
      end
      if @failed
        raise @failure.not_nil!
      end
      spans = @spans.dup
      completed = interval_of(@clock.now_ms)
      metrics = [] of Metric
      @measurements.reject! do |_, metric|
        next false if !partial && metric.interval >= completed
        metrics << metric
        true
      end
      @in_flight_measurements = metrics.size
      writing = @writing = Future(Nil).new
      begin
        write(spans, metrics)
        @spans.shift(spans.size)
        writing.resolve(nil)
      rescue error
        @failed = @stopped = true
        @failure = error
        @spans.clear
        @measurements.clear
        @stop_timer.call
        writing.reject(error)
        raise error
      ensure
        @writing = nil
        @in_flight_measurements = 0
      end
    end

    private def write(spans : Array(Array(Sqlite::Value)), metrics : Array(Metric)) : Nil
      @db.transaction do |transaction|
        spans.each { |span| transaction.run_values(INSERT_SPAN, span) }
        metrics.each { |metric| transaction.run_values(INSERT_METRIC, metric.values) }
        cutoff = @clock.now_ms - @retention.total_milliseconds.to_i64
        transaction.run("DELETE FROM telemetry_spans WHERE ended_ms < ?", cutoff)
        transaction.run("DELETE FROM telemetry_metrics WHERE interval_ms < ?", cutoff)
      end
    end

    protected def self.identity_of(context : LLM::Telemetry::TelemetryContext) : Identity?
      case context
      when LiveSpan        then context.identity
      when ExtractedParent then context.identity
      end
    end

    protected def self.link_json(link : LLM::Telemetry::SpanLink) : JSON::Any?
      identity_of(link.context).try do |identity|
        JSON::Any.new({
          "trace_id"   => JSON::Any.new(identity.trace_id),
          "span_id"    => JSON::Any.new(identity.id),
          "attributes" => attributes_json(link.attributes),
        })
      end
    end

    protected def self.status_json(status : LLM::Telemetry::SpanStatus) : JSON::Any
      fields = {"status" => JSON::Any.new(status.ok? ? "ok" : "error")}
      if status.error? && (error = status.error)
        fields["error"] = JSON::Any.new({"name" => JSON::Any.new(error.name), "message" => JSON::Any.new(error.message)})
      end
      JSON::Any.new(fields)
    end

    protected def self.attributes_json(attributes : LLM::Telemetry::Attributes?) : JSON::Any
      JSON::Any.new(attributes ? attributes_hash(attributes) : {} of String => JSON::Any)
    end

    protected def self.attributes_hash(attributes : LLM::Telemetry::Attributes) : Hash(String, JSON::Any)
      result = Hash(String, JSON::Any).new(initial_capacity: attributes.size)
      attributes.each { |key, value| result[key] = attribute_json(value) }
      result
    end

    private def self.attribute_json(value : LLM::Telemetry::AttributeValue) : JSON::Any
      case value
      when Array then JSON::Any.new(value.map { |item| JSON::Any.new(item) })
      else            JSON::Any.new(value)
      end
    end
  end

  def self.create_sqlite_telemetry(db : Sqlite::Database, *, retention : Time::Span = SqliteTelemetry::DEFAULT_RETENTION,
                                   max_queued_spans : Int = SqliteTelemetry::DEFAULT_MAX_QUEUED_SPANS,
                                   clock : LLM::Telemetry::Clock = LLM::Telemetry::SYSTEM_CLOCK) : SqliteTelemetry
    Sqlite.apply_migrations(db, SqliteTelemetry::MIGRATIONS, table: "telemetry_schema")
    SqliteTelemetry.new(db, retention, max_queued_spans.to_i32, clock)
  end
end
