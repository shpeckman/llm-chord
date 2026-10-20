# src/llm/chord/telemetry/render.cr
module LLM::Chord::Telemetry
  def self.render_trace(spans : Enumerable(StoredSpan)) : String
    by_id = {} of String => StoredSpan
    spans.each { |span| by_id[span.id] = span }
    ordered = by_id.values.each_with_index.to_a.sort! do |(left, left_index), (right, right_index)|
      compared = left.started_ms <=> right.started_ms
      compared == 0 ? left_index <=> right_index : compared
    end
    roots = [] of StoredSpan
    children = {} of String => Array(StoredSpan)
    ordered.each do |(span, _)|
      parent = span.parent_id
      if parent.nil? || !by_id.has_key?(parent)
        roots << span
      else
        (children[parent] ||= [] of StoredSpan) << span
      end
    end

    lines = [] of String
    pending = roots.reverse.map { |span| {span, 0} }
    while entry = pending.pop?
      span, depth = entry
      indent = "  " * depth
      error = ""
      unless span.status.ok?
        error = " error"
        span.status.error.try { |detail| error += " #{detail.name}: #{detail.message}" }
      end
      lines << "#{indent}#{span.name}#{format_attributes(span.attributes)} (#{duration(span.ended_ms - span.started_ms)}ms)#{error}"
      span.events.each do |event|
        lines << "#{indent}  · #{event.name}#{format_attributes(event.attributes)} (+#{duration(event.time_ms)}ms)"
      end
      span.links.each do |link|
        lines << "#{indent}  → link trace #{link.trace_id} span #{link.span_id}#{format_attributes(link.attributes)}"
      end
      if descendants = children[span.id]?
        descendants.reverse_each { |child| pending << {child, depth + 1} }
      end
    end
    lines.join('\n')
  end

  private def self.format_attributes(attributes : Attributes?) : String
    return "" unless attributes
    String.build do |io|
      attributes.each do |key, value|
        io << ' ' << key << '='
        write_value(io, value)
      end
    end
  end

  private def self.write_value(io : IO, value : AttributeValue) : Nil
    case value
    when String  then value.to_json(io)
    when Int64   then io << value
    when Float64 then io << Json.number_text(value)
    when Bool    then io << value
    when Array
      io << '['
      value.each_with_index do |item, index|
        io << ',' unless index == 0
        write_value(io, item)
      end
      io << ']'
    end
  end

  private def self.duration(milliseconds : Float64) : String
    Json.number_text(milliseconds)
  end
end
