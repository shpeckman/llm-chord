# src/llm/chord/telemetry_sqlite/store.cr
module LLM::Chord
  class SqliteTelemetry
    alias QueryAttributes = Hash(String, LLM::Telemetry::QueryValue)

    SELECT_TRACE = "SELECT * FROM telemetry_spans WHERE trace_id = ? ORDER BY started_ms, id"
    SELECT_PAGE  = "SELECT * FROM telemetry_spans WHERE trace_id IN (SELECT value FROM json_each(?)) ORDER BY started_ms, id"
    FIRST_NAME   = "(SELECT name FROM telemetry_spans WHERE trace_id = heads.trace_id ORDER BY started_ms, id LIMIT 1) = ?"
    ANY_ERROR    = "EXISTS (SELECT 1 FROM telemetry_spans WHERE trace_id = heads.trace_id AND json_extract(status, '$.status') = 'error')"

    def self.get_trace(db : Sqlite::Database, trace_id : String) : LLM::Telemetry::StoredTrace?
      rows = db.all(SELECT_TRACE, trace_id)
      rows.empty? ? nil : LLM::Telemetry::StoredTrace.new(trace_id, rows.map { |row| stored_span(row) })
    end

    def self.find_traces(db : Sqlite::Database, query : TraceQuery = TraceQuery.new) : LLM::Telemetry::TracePage
      conditions = [] of String
      params = [] of Sqlite::Value
      if name = query.name
        conditions << FIRST_NAME
        params << name
      end
      if start_min = query.start_min
        conditions << "started_ms >= ?"
        params << start_min
      end
      if start_max = query.start_max
        conditions << "started_ms <= ?"
        params << start_max
      end
      conditions << ANY_ERROR if query.errors
      if attributes = query.attributes
        conditions << "EXISTS (SELECT 1 FROM telemetry_spans candidate WHERE candidate.trace_id = heads.trace_id AND " \
                      "#{attributes_sql(attributes, "candidate.attributes", params)})"
      end
      if cursor = query.cursor
        position = JSON.parse(cursor).as_a
        conditions << "(started_ms < ? OR (started_ms = ? AND trace_id > ?))"
        params << number(position[0]) << number(position[0]) << position[1].as_s
      end
      params << (query.limit + 1).to_i64
      where = conditions.empty? ? "1" : conditions.join(" AND ")
      db.transaction do |transaction|
        heads = transaction.all_values(<<-SQL, params)
          WITH heads AS (
          			SELECT trace_id, min(started_ms) started_ms FROM telemetry_spans GROUP BY trace_id
          		) SELECT * FROM heads WHERE #{where} ORDER BY started_ms DESC, trace_id LIMIT ?
          SQL
        more = heads.size > query.limit
        heads.pop if more
        next LLM::Telemetry::TracePage.new([] of LLM::Telemetry::StoredTrace) if heads.empty?
        ids = heads.map { |head| JSON::Any.new(head["trace_id"].as(String)) }
        grouped = {} of String => Array(LLM::Telemetry::StoredSpan)
        transaction.all(SELECT_PAGE, Schema.stringify(JSON::Any.new(ids))).each do |row|
          (grouped[row["trace_id"].as(String)] ||= [] of LLM::Telemetry::StoredSpan) << stored_span(row)
        end
        traces = heads.map do |head|
          trace_id = head["trace_id"].as(String)
          LLM::Telemetry::StoredTrace.new(trace_id, grouped[trace_id])
        end
        last = heads.last
        cursor = more ? Schema.stringify(JSON::Any.new([JSON::Any.new(real(last["started_ms"])), JSON::Any.new(last["trace_id"].as(String))])) : nil
        LLM::Telemetry::TracePage.new(traces, cursor)
      end
    end

    def self.find_metrics(db : Sqlite::Database, query : LLM::Telemetry::MetricQuery) : Array(LLM::Telemetry::StoredMetric)
      params = [query.name] of Sqlite::Value
      conditions = ["name = ?"]
      if start_min = query.start_min
        conditions << "interval_ms >= ?"
        params << start_min
      end
      if start_max = query.start_max
        conditions << "interval_ms <= ?"
        params << start_max
      end
      conditions << attributes_sql(query.attributes, "attributes", params)
      sql = "SELECT * FROM telemetry_metrics WHERE #{conditions.join(" AND ")} ORDER BY interval_ms, series_key"
      db.all_values(sql, params).map do |row|
        LLM::Telemetry::StoredMetric.new(
          row["interval_ms"].as(Int64), row["name"].as(String), metric_kind(row["kind"].as(String)), row["unit"].as(String?),
          parse_attributes(JSON.parse(row["attributes"].as(String))), row["count"].as(Int64),
          real(row["sum"]), real(row["min"]), real(row["max"]))
      end
    end

    private def self.attributes_sql(attributes : QueryAttributes?, column : String, params : Array(Sqlite::Value)) : String
      return "1" if attributes.nil? || attributes.empty?
      attributes.join(" AND ") do |key, value|
        type = case value
               when Int64, Float64 then "entry.type IN ('integer', 'real')"
               when Bool           then "entry.type = '#{value}'"
               else                     "entry.type = 'text'"
               end
        params << key << (value.is_a?(Bool) ? (value ? 1_i64 : 0_i64) : value)
        "EXISTS (SELECT 1 FROM json_each(#{column}) entry WHERE entry.key = ? AND #{type} AND entry.value = ?)"
      end
    end

    private def self.stored_span(row : Sqlite::Row) : LLM::Telemetry::StoredSpan
      LLM::Telemetry::StoredSpan.new(
        row["id"].as(String), row["trace_id"].as(String), row["parent_id"].as(String?), row["name"].as(String),
        real(row["started_ms"]), real(row["ended_ms"]),
        parse_attributes(JSON.parse(row["attributes"].as(String))),
        JSON.parse(row["events"].as(String)).as_a.map { |event| stored_event(event) },
        JSON.parse(row["links"].as(String)).as_a.map { |link| stored_link(link) },
        parse_status(JSON.parse(row["status"].as(String))))
    end

    private def self.stored_event(event : JSON::Any) : LLM::Telemetry::StoredEvent
      LLM::Telemetry::StoredEvent.new(event["name"].as_s, number(event["time_ms"]), parse_attributes(event["attributes"]))
    end

    private def self.stored_link(link : JSON::Any) : LLM::Telemetry::StoredLink
      LLM::Telemetry::StoredLink.new(link["trace_id"].as_s, link["span_id"].as_s, link["attributes"]?.try { |attributes| parse_attributes(attributes) })
    end

    private def self.parse_status(status : JSON::Any) : LLM::Telemetry::SpanStatus
      return LLM::Telemetry::SpanStatus.ok if status["status"].as_s == "ok"
      error = status["error"]?
      error ? LLM::Telemetry::SpanStatus.error(error["name"].as_s, error["message"].as_s) : LLM::Telemetry::SpanStatus.error
    end

    private def self.metric_kind(label : String) : LLM::Telemetry::MetricKind
      LLM::Telemetry::MetricKind.values.find(&.label.==(label)) || raise Sqlite::Error.new("Unknown metric kind #{label}")
    end

    protected def self.parse_attributes(json : JSON::Any) : LLM::Telemetry::Attributes
      result = LLM::Telemetry::Attributes.new
      json.as_h.each do |key, value|
        parse_attribute(value).try { |parsed| result[key] = parsed }
      end
      result
    end

    private def self.parse_attribute(value : JSON::Any) : LLM::Telemetry::AttributeValue?
      case raw = value.raw
      when String, Int64, Float64, Bool then raw
      when Array                        then parse_list(raw)
      end
    end

    private def self.parse_list(items : Array(JSON::Any)) : LLM::Telemetry::AttributeValue
      raws = items.map(&.raw)
      if raws.all?(String)
        raws.map(&.as(String))
      elsif raws.all?(Bool)
        raws.map(&.as(Bool))
      elsif raws.all?(Int64)
        raws.map(&.as(Int64))
      else
        raws.map { |raw| raw.is_a?(Int64 | Float64) ? raw.to_f64 : Float64::NAN }
      end
    end

    private def self.number(value : JSON::Any) : Float64
      value.as_f? || value.as_i64.to_f64
    end

    private def self.real(value : Sqlite::Value) : Float64
      case value
      when Float64 then value
      when Int64   then value.to_f64
      else              raise Sqlite::Error.new("Expected a number, got #{value.inspect}")
      end
    end
  end
end
