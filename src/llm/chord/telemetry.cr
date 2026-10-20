# src/llm/chord/telemetry.cr
module LLM::Chord::Telemetry
  alias AttributeValue = String | Int64 | Float64 | Bool | Array(String) | Array(Int64) | Array(Float64) | Array(Bool)
  alias Attributes = Hash(String, AttributeValue)
  alias Carrier = Hash(String, String)
  alias QueryValue = String | Int64 | Float64 | Bool

  def self.attributes(**values) : Attributes
    result = Attributes.new
    values.each { |key, value| result[key.to_s] = attribute(value) }
    result
  end

  def self.attribute(value : String | Bool | Int64 | Float64) : AttributeValue
    value
  end

  def self.attribute(value : Int) : AttributeValue
    value.to_i64
  end

  def self.attribute(value : Float) : AttributeValue
    value.to_f64
  end

  def self.attribute(value : Array(String) | Array(Int64) | Array(Float64) | Array(Bool)) : AttributeValue
    value.dup
  end

  def self.attribute(value : Array(Int)) : AttributeValue
    value.map(&.to_i64)
  end

  def self.attribute(value : Array(Float)) : AttributeValue
    value.map(&.to_f64)
  end

  def self.copy_attributes(attributes : Attributes?) : Attributes
    result = Attributes.new
    attributes.try &.each do |key, value|
      result[key] = value.is_a?(Array) ? value.dup : value
    end
    result
  end

  record SpanError, name : String, message : String

  struct SpanStatus
    getter error : SpanError?

    def initialize(@ok : Bool, @error : SpanError? = nil); end

    def self.ok : SpanStatus
      new(true)
    end

    def self.error(error : SpanError? = nil) : SpanStatus
      new(false, error)
    end

    def self.error(name : String, message : String) : SpanStatus
      new(false, SpanError.new(name, message))
    end

    def ok? : Bool
      @ok
    end

    def error? : Bool
      !@ok
    end
  end

  record SpanLink, context : TelemetryContext, attributes : Attributes? = nil

  record SpanOptions, name : String, attributes : Attributes? = nil, links : Array(SpanLink)? = nil

  record InstrumentOptions, description : String? = nil, unit : String? = nil, boundaries : Array(Float64)? = nil

  abstract class Counter
    abstract def add(value : Number, attributes : Attributes? = nil) : Nil
  end

  abstract class UpDownCounter
    abstract def add(value : Number, attributes : Attributes? = nil) : Nil
  end

  abstract class Histogram
    abstract def record(value : Number, attributes : Attributes? = nil, context : TelemetryContext? = nil) : Nil
  end

  module Metrics
    abstract def counter(name : String, options : InstrumentOptions? = nil) : Counter
    abstract def up_down_counter(name : String, options : InstrumentOptions? = nil) : UpDownCounter
    abstract def histogram(name : String, options : InstrumentOptions? = nil) : Histogram
  end

  module Propagation
    abstract def inject(context : TelemetryContext) : Carrier?
    abstract def extract(carrier : Carrier?) : TelemetryContext
  end

  abstract class TelemetryContext
    def metrics : Metrics?
      nil
    end

    def propagation : Propagation?
      nil
    end

    abstract def start_span(options : SpanOptions, & : TelemetrySpan -> _)

    def start_span(name : String, &)
      start_span(SpanOptions.new(name)) { |span| yield span }
    end
  end

  abstract class TelemetrySpan < TelemetryContext
    abstract def add_link(link : SpanLink) : Nil
    abstract def add_event(name : String, attributes : Attributes? = nil) : Nil
    abstract def merge_attributes(attributes : Attributes) : Nil
    abstract def status=(status : SpanStatus) : Nil
  end

  enum MetricKind
    Counter
    UpDownCounter
    Histogram

    def label : String
      case self
      in .counter?         then "counter"
      in .up_down_counter? then "upDownCounter"
      in .histogram?       then "histogram"
      end
    end
  end

  record StoredEvent, name : String, time_ms : Float64, attributes : Attributes
  record StoredLink, trace_id : String, span_id : String, attributes : Attributes? = nil
  record StoredSpan, id : String, trace_id : String, parent_id : String?, name : String,
    started_ms : Float64, ended_ms : Float64, attributes : Attributes,
    events : Array(StoredEvent), links : Array(StoredLink), status : SpanStatus
  record StoredTrace, trace_id : String, spans : Array(StoredSpan)
  record TracePage, traces : Array(StoredTrace), cursor : String? = nil
  record TraceQuery, name : String? = nil, attributes : Hash(String, QueryValue)? = nil, errors : Bool = false,
    start_min : Float64? = nil, start_max : Float64? = nil, limit : Int32 = 20, cursor : String? = nil
  record MetricQuery, name : String, start_min : Int64? = nil, start_max : Int64? = nil,
    attributes : Hash(String, QueryValue)? = nil
  record StoredMetric, interval_ms : Int64, name : String, kind : MetricKind, unit : String?,
    attributes : Attributes, count : Int64, sum : Float64, min : Float64, max : Float64

  module TelemetryStore
    abstract def find_traces(query : TraceQuery = TraceQuery.new) : TracePage
    abstract def get_trace(trace_id : String) : StoredTrace?
    abstract def find_metrics(query : MetricQuery) : Array(StoredMetric)
  end

  class NoopCounter < Counter
    def add(value : Number, attributes : Attributes? = nil) : Nil
    end
  end

  class NoopUpDownCounter < UpDownCounter
    def add(value : Number, attributes : Attributes? = nil) : Nil
    end
  end

  class NoopHistogram < Histogram
    def record(value : Number, attributes : Attributes? = nil, context : TelemetryContext? = nil) : Nil
    end
  end

  class NoopMetrics
    include Metrics

    COUNTER         = NoopCounter.new
    UP_DOWN_COUNTER = NoopUpDownCounter.new
    HISTOGRAM       = NoopHistogram.new

    def counter(name : String, options : InstrumentOptions? = nil) : Counter
      COUNTER
    end

    def up_down_counter(name : String, options : InstrumentOptions? = nil) : UpDownCounter
      UP_DOWN_COUNTER
    end

    def histogram(name : String, options : InstrumentOptions? = nil) : Histogram
      HISTOGRAM
    end
  end

  class NoopPropagation
    include Propagation

    def inject(context : TelemetryContext) : Carrier?
      nil
    end

    def extract(carrier : Carrier?) : TelemetryContext
      NOOP
    end
  end

  class NoopSpan < TelemetrySpan
    def metrics : Metrics?
      NOOP_METRICS
    end

    def propagation : Propagation?
      NOOP_PROPAGATION
    end

    def start_span(options : SpanOptions, &)
      yield self
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

  NOOP_METRICS     = NoopMetrics.new
  NOOP_PROPAGATION = NoopPropagation.new
  NOOP             = NoopSpan.new
end
