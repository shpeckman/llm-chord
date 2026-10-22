# src/llm-chord/schema.cr
require "typebox"

module LLM::Chord::Schema
  alias Source = TypeBox::Schema | JSON::Any
  alias Fields = Hash(String, JSON::Any)

  CONSTRAINTS = {
    "minLength", "maxLength", "pattern", "format", "minimum", "maximum", "exclusiveMinimum",
    "exclusiveMaximum", "multipleOf", "minItems", "maxItems", "uniqueItems", "minProperties", "maxProperties",
  }

  KNOWN = ::Set(String).new(CONSTRAINTS.to_a + %w[
    type properties required additionalProperties patternProperties items additionalItems const enum anyOf
    parameters returnType
  ])

  ANNOTATIONS = ::Set{
    "title", "description", "default", "examples", "$id", "$schema", "$comment", "readOnly", "writeOnly", "deprecated",
  }

  def self.json(schema : Source) : JSON::Any
    schema.is_a?(TypeBox::Schema) ? schema.json : schema
  end

  def self.canonical_json(value : JSON::Any?) : String
    String.build { |io| write_json(io, value, true) }
  end

  def self.stringify(value : JSON::Any?) : String
    String.build { |io| write_json(io, value, false) }
  end

  def self.canonical_json(value : TypeBox::Schema) : String
    canonical_json(value.json)
  end

  def self.hash64(text : String) : String
    a = 0x811c9dc5_u32
    b = 0x01000193_u32 ^ 0x5bd1e995_u32
    text.to_utf16.each do |unit|
      code = unit.to_u32
      a = (a ^ code) &* 0x01000193_u32
      b = ((b ^ code) &* 0x5bd1e995_u32) ^ (b >> 13)
    end
    a.to_s(16).rjust(8, '0') + b.to_s(16).rjust(8, '0')
  end

  def self.deep_equal?(left : JSON::Any?, right : JSON::Any?) : Bool
    TypeBox::Guard.strict_equal?(left, right) || canonical_json(left) == canonical_json(right)
  end

  def self.assert_valid(reason : String, what : String, schema : Source, value : JSON::Any?) : Nil
    return if TypeBox::Value.check(schema, value)
    errors = TypeBox::Value.errors(schema, value).first(3)
    summary = errors.join("; ") { |error| "#{error.instance_path.empty? ? "/" : error.instance_path} #{error.message}" }
    raise Chord.invalid(reason, "#{what}: #{summary}", JSON.parse(errors.to_json))
  end

  def self.normalize(schema : Source, value : JSON::Any?, what : String) : JSON::Any?
    start = value.nil? || value.raw.nil? ? JSON::Any.new(Fields.new) : TypeBox::Value.clone(value)
    normalized = TypeBox::Value.clean(schema, TypeBox::Value.default(schema, start))
    assert_valid("input", what, schema, normalized)
    normalized
  end

  def self.canonical_identity(schema : Source, value : JSON::Any?) : String
    canonical_json(strip_defaults(as_schema(json(schema)), value))
  end

  def self.fits?(sub_schema : Source?, sup_schema : Source?) : Bool
    sub = without_annotations(as_schema(sub_schema.try { |schema| json(schema) }))
    sup = without_annotations(as_schema(sup_schema.try { |schema| json(schema) }))
    return true if sup.empty?
    return true if deep_equal?(JSON::Any.new(sub), JSON::Any.new(sup))
    return false if sup.keys.any? { |key| !KNOWN.includes?(key) }
    if (additional = sup["additionalProperties"]?) && !additional.raw.is_a?(Bool)
      return false
    end
    if branches = sub["anyOf"]?.try(&.as_a?)
      return branches.all? { |branch| fits?(branch, JSON::Any.new(sup)) }
    end
    if branches = sup["anyOf"]?.try(&.as_a?)
      return branches.any? { |branch| fits?(JSON::Any.new(sub), branch) }
    end
    if sup.has_key?("const")
      return sub.has_key?("const") && deep_equal?(sub["const"], sup["const"])
    end
    if allowed = sup["enum"]?.try(&.as_a?)
      values = sub.has_key?("const") ? [sub["const"]] : sub["enum"]?.try(&.as_a?)
      return values ? values.all? { |item| allowed.any? { |option| deep_equal?(option, item) } } : false
    end
    CONSTRAINTS.each { |key| return false if sup.has_key?(key) && !deep_equal?(sub[key]?, sup[key]) }
    sup_types = types_of(sup)
    sub_types = types_of(sub)
    return false unless sup_types && sub_types
    return false unless sub_types.all? { |type| sup_types.includes?(type) || (type == "integer" && sup_types.includes?("number")) }
    return true if sub.has_key?("const") || sub["enum"]?.try(&.as_a?)
    return false if sub_types.includes?("object") && !object_fits?(sub, sup)
    return false if sub_types.includes?("array") && !array_fits?(sub, sup)
    return function_fits?(sub, sup) if sub_types.includes?("function")
    true
  end

  private def self.write_json(io : IO, value : JSON::Any?, sorted : Bool) : Nil
    case raw = value.try(&.raw)
    when Nil            then io << "null"
    when Bool           then io << raw
    when Int64, Float64 then io << (raw.is_a?(Float64) && !raw.finite? ? "null" : TypeBox::Guard.js_number(raw))
    when String         then write_string(io, raw)
    when Array
      io << '['
      raw.each_with_index do |item, index|
        io << ',' if index > 0
        write_json(io, item, sorted)
      end
      io << ']'
    when Hash
      io << '{'
      keys = sorted ? raw.keys.sort_by!(&.to_utf16.to_a) : raw.keys
      keys.each_with_index do |key, index|
        io << ',' if index > 0
        write_string(io, key)
        io << ':'
        write_json(io, raw[key], sorted)
      end
      io << '}'
    end
  end

  private def self.write_string(io : IO, text : String) : Nil
    io << '"'
    text.each_char do |char|
      case char
      when '"'  then io << "\\\""
      when '\\' then io << "\\\\"
      when '\b' then io << "\\b"
      when '\f' then io << "\\f"
      when '\n' then io << "\\n"
      when '\r' then io << "\\r"
      when '\t' then io << "\\t"
      else
        if char.ord < 0x20
          io << "\\u" << char.ord.to_s(16).rjust(4, '0')
        else
          io << char
        end
      end
    end
    io << '"'
  end

  private def self.as_schema(schema : JSON::Any?) : Fields
    case raw = schema.try(&.raw)
    when Hash  then raw
    when Array then raw.each_with_index.to_h { |item, index| {index.to_s, item} }
    when false then {"not" => JSON::Any.new(Fields.new)}
    else            Fields.new
    end
  end

  private def self.without_annotations(schema : Fields) : Fields
    schema.reject { |key, _| ANNOTATIONS.includes?(key) }
  end

  private def self.types_of(schema : Fields) : Array(JSON::Any)?
    type = schema["type"]?
    return unless type
    type.raw.is_a?(String) ? [type] : type.as_a?
  end

  private def self.strip_defaults(schema : Fields, value : JSON::Any?) : JSON::Any?
    return value unless value
    case raw = value.raw
    when Array
      items = schema["items"]?
      if tuple = items.try(&.as_a?)
        JSON::Any.new(raw.map_with_index { |item, index| strip_defaults(as_schema(tuple[index]?), item) || JSON::Any.new(nil) })
      else
        JSON::Any.new(raw.map { |item| strip_defaults(as_schema(items), item) || JSON::Any.new(nil) })
      end
    when Hash
      properties = as_schema(schema["properties"]?)
      result = Fields.new
      TypeBox::Guard.keys(value).each do |key|
        item = raw[key]
        property = as_schema(properties[key]?)
        next if property.has_key?("default") && deep_equal?(property["default"], item)
        result[key] = strip_defaults(property, item) || JSON::Any.new(nil)
      end
      JSON::Any.new(result)
    else
      value
    end
  end

  private def self.string_list(value : JSON::Any?) : Array(String)
    value.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
  end

  private def self.object_fits?(sub : Fields, sup : Fields) : Bool
    sub_properties = as_schema(sub["properties"]?)
    sup_properties = as_schema(sup["properties"]?)
    sub_required = string_list(sub["required"]?).to_set
    string_list(sup["required"]?).each { |key| return false unless sub_required.includes?(key) }
    sup_properties.each do |key, property|
      if sub_property = sub_properties[key]?
        return false unless fits?(sub_property, property)
      elsif (additional = sub["additionalProperties"]?) && !additional.raw.is_a?(Bool | String | Int64 | Float64) && !fits?(additional, property)
        return false
      end
    end
    if sup["additionalProperties"]?.try(&.raw) == false
      return false unless sub["additionalProperties"]?.try(&.raw) == false
      return false if sub_properties.keys.any? { |key| !sup_properties.has_key?(key) }
    end
    sup_patterns = as_schema(sup["patternProperties"]?)
    unless sup_patterns.empty?
      sub_patterns = as_schema(sub["patternProperties"]?)
      return false if sub["additionalProperties"]?.try(&.raw) != false && sub_patterns.empty?
      sup_patterns.each do |pattern, property|
        sub_properties.each do |key, sub_property|
          if !sup_properties.has_key?(key) && TypeBox::JsRegex.test(pattern, key, "u") && !fits?(sub_property, property)
            return false
          end
        end
        if !sub_patterns.empty? && (!(sub_pattern = sub_patterns[pattern]?) || !fits?(sub_pattern, property))
          return false
        end
      end
      sub_patterns.each_key { |pattern| return false unless sup_patterns.has_key?(pattern) }
    end
    true
  end

  private def self.array_fits?(sub : Fields, sup : Fields) : Bool
    sub_items = sub["items"]?
    sup_items = sup["items"]?
    if sup_tuple = sup_items.try(&.as_a?)
      sub_tuple = sub_items.try(&.as_a?)
      return false unless sub_tuple && sub_tuple.size == sup_tuple.size
      return sub_tuple.each_with_index.all? { |(item, index)| fits?(item, sup_tuple[index]) }
    end
    if sub_tuple = sub_items.try(&.as_a?)
      return sub_tuple.all? { |item| fits?(item, sup_items) }
    end
    fits?(sub_items, sup_items)
  end

  private def self.function_fits?(sub : Fields, sup : Fields) : Bool
    sub_parameters = sub["parameters"]?.try(&.as_a?) || [] of JSON::Any
    sup_parameters = sup["parameters"]?.try(&.as_a?) || [] of JSON::Any
    return false if sub_parameters.size > sup_parameters.size
    return false unless sub_parameters.each_with_index.all? { |(parameter, index)| fits?(sup_parameters[index]?, parameter) }
    fits?(sub["returnType"]?, sup["returnType"]?)
  end
end
