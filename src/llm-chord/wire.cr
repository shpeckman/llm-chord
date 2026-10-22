# src/llm-chord/wire.cr
require "base64"
require "compress/deflate"

module LLM::Chord
  PROTOCOL_VERSION = 4
  PACK_THRESHOLD   = 64 * 1024

  class Packed
    getter field : String
    getter bytes : Bytes

    def initialize(@field : String, @bytes : Bytes); end

    def self.deflate(field : String, json : String) : Packed
      io = IO::Memory.new
      Compress::Deflate::Writer.open(io, level: 1) { |deflate| deflate << json }
      new(field, io.to_slice)
    end

    def json : String
      Compress::Deflate::Reader.open(IO::Memory.new(@bytes)) { |inflate| inflate.gets_to_end }
    end

    def unpack : JSON::Any
      JSON.parse(json)
    end
  end

  class Frame
    PAYLOAD_FIELDS = {"args", "value"}

    getter fields : Hash(String, JSON::Any)
    getter packed : Packed?

    def initialize(@fields : Hash(String, JSON::Any), @packed : Packed? = nil); end

    def self.build(t : String, **fields) : Frame
      hash = {"t" => JSON::Any.new(t)}
      fields.each { |key, value| hash[key.to_s] = Frame.json(value) unless value.nil? }
      new(hash)
    end

    def self.state(hold : Int64, m : String, kind : String, value : JSON::Any? = nil, ops : Array(JSON::Any)? = nil,
                   error : JSON::Any? = nil) : Frame
      fields = {
        "t"    => JSON::Any.new("state"),
        "hold" => JSON::Any.new(hold),
        "m"    => JSON::Any.new(m),
        "as"   => JSON::Any.new(kind),
      }
      value.try { |payload| fields["value"] = payload }
      ops.try { |list| fields["ops"] = JSON::Any.new(list) }
      error.try { |failure| fields["error"] = failure }
      new(fields)
    end

    def self.json(value : JSON::Any) : JSON::Any
      value
    end

    def self.json(value : Int) : JSON::Any
      JSON::Any.new(value.to_i64)
    end

    def self.json(value : String | Bool | Float64) : JSON::Any
      JSON::Any.new(value)
    end

    def self.json(value : Array(String)) : JSON::Any
      JSON::Any.new(value.map { |item| JSON::Any.new(item) })
    end

    def self.json(value : Array(JSON::Any)) : JSON::Any
      JSON::Any.new(value)
    end

    def self.json(value : Hash(String, JSON::Any)) : JSON::Any
      JSON::Any.new(value)
    end

    def t : String
      @fields["t"].as_s
    end

    def [](key : String) : JSON::Any
      @fields[key]
    end

    def []?(key : String) : JSON::Any?
      @fields[key]?
    end

    def int(key : String) : Int64
      @fields[key].as_i64
    end

    def string(key : String) : String
      @fields[key].as_s
    end

    def string?(key : String) : String?
      @fields[key]?.try(&.as_s?)
    end

    def payload_field : String?
      case t
      when "call"            then present?("args") ? "args" : nil
      when "result", "state" then present?("value") ? "value" : nil
      end
    end

    def payload? : Bool
      !payload_field.nil?
    end

    def payload : JSON::Any?
      field = payload_field
      return unless field
      @fields[field]? || @packed.try(&.unpack)
    end

    def with(key : String, value : JSON::Any) : Frame
      copy = @fields.dup
      copy[key] = value
      Frame.new(copy, @packed)
    end

    def without(key : String) : Frame
      copy = @fields.dup
      copy.delete(key)
      Frame.new(copy, @packed.try { |packed| packed.field == key ? nil : packed })
    end

    def to_json(builder : JSON::Builder) : Nil
      builder.object do
        @fields.each { |key, value| builder.field(key) { value.to_json(builder) } }
        if packed = @packed
          builder.field(packed.field) { builder.raw(packed.json) }
        end
      end
    end

    def inspect(io : IO) : Nil
      io << "Frame(" << to_json << ')'
    end

    private def present?(field : String) : Bool
      @fields.has_key?(field) || @packed.try(&.field) == field
    end
  end

  module Wire
    ID     = TypeBox::Type.integer(minimum: 1)
    NAME   = TypeBox::Type.string(minLength: 1)
    RELOAD = TypeBox::Type.integer(minimum: 1)

    ROOT_REF = TypeBox::Type.object({rootId: NAME, codeVersion: TypeBox::Type.integer(minimum: 1)})

    ERROR = TypeBox::Type.object({
      code:    TypeBox::Type.enum(ErrorCode.values.map(&.label)),
      message: TypeBox::Type.string,
      reason:  TypeBox::Type.optional(TypeBox::Type.string),
    })

    RELOAD_OPTIONS = TypeBox::Type.object({
      remove:         TypeBox::Type.optional(TypeBox::Type.array(TypeBox::Type.string)),
      gateDeadline:   TypeBox::Type.optional(TypeBox::Type.number),
      retireDeadline: TypeBox::Type.optional(TypeBox::Type.number),
    })

    RELOAD_REPORT = TypeBox::Type.object({
      codeVersion: TypeBox::Type.integer,
      previous:    TypeBox::Type.integer,
      changed:     TypeBox::Type.array(TypeBox::Type.string),
      removed:     TypeBox::Type.array(TypeBox::Type.string),
      prepared:    TypeBox::Type.array(TypeBox::Type.string),
      gated:       TypeBox::Type.array(TypeBox::Type.string),
    })

    FRAME_SCHEMA = TypeBox::Type.union([
      TypeBox::Type.object({
        t:           TypeBox::Type.literal("hello"),
        protocol:    TypeBox::Type.optional(TypeBox::Type.integer(minimum: 1)),
        name:        NAME,
        kind:        TypeBox::Type.union([TypeBox::Type.literal("host"), TypeBox::Type.literal("client")]),
        codeVersion: TypeBox::Type.integer(minimum: 0),
        acks:        TypeBox::Type.optional(TypeBox::Type.boolean),
      }),
      TypeBox::Type.object({t: TypeBox::Type.literal("ack"), n: TypeBox::Type.integer(minimum: 1)}),
      TypeBox::Type.object({
        t:         TypeBox::Type.literal("hold"),
        id:        ID,
        at:        NAME,
        token:     DESCRIPTION_SCHEMA,
        input:     TypeBox::Type.unknown,
        principal: TypeBox::Type.optional(TypeBox::Type.unknown),
        origin:    TypeBox::Type.optional(NAME),
        state:     TypeBox::Type.optional(TypeBox::Type.literal(false)),
        again:     TypeBox::Type.optional(TypeBox::Type.literal(true)),
      }),
      TypeBox::Type.object({t: TypeBox::Type.literal("release"), id: ID}),
      TypeBox::Type.object({
        t:        TypeBox::Type.literal("shape"),
        id:       ID,
        variant:  TypeBox::Type.optional(TypeBox::Type.string),
        members:  TypeBox::Type.array(TypeBox::Type.string),
        contract: TypeBox::Type.string,
        state:    TypeBox::Type.array(NAME),
      }),
      TypeBox::Type.object({t: TypeBox::Type.literal("gone"), id: ID, error: ERROR}),
      TypeBox::Type.object({
        t:      TypeBox::Type.literal("call"),
        id:     ID,
        hold:   ID,
        member: NAME,
        args:   TypeBox::Type.optional(TypeBox::Type.unknown),
        root:   TypeBox::Type.optional(ROOT_REF),
      }),
      TypeBox::Type.object({
        t:     TypeBox::Type.literal("result"),
        id:    ID,
        value: TypeBox::Type.optional(TypeBox::Type.unknown),
        error: TypeBox::Type.optional(ERROR),
      }),
      TypeBox::Type.object({t: TypeBox::Type.literal("cancel"), id: ID}),
      TypeBox::Type.object({t: TypeBox::Type.literal("sub"), hold: ID}),
      TypeBox::Type.object({t: TypeBox::Type.literal("unsub"), hold: ID}),
      TypeBox::Type.object({t: TypeBox::Type.literal("resync"), hold: ID, m: NAME}),
      TypeBox::Type.object({
        t:     TypeBox::Type.literal("state"),
        hold:  ID,
        m:     NAME,
        as:    TypeBox::Type.union(%w[snap reset ops error].map { |kind| TypeBox::Type.literal(kind) }),
        value: TypeBox::Type.optional(TypeBox::Type.unknown),
        ops:   TypeBox::Type.optional(TypeBox::Type.array(TypeBox::Type.array(TypeBox::Type.unknown))),
        error: TypeBox::Type.optional(ERROR),
      }),
      TypeBox::Type.object({t: TypeBox::Type.literal("ping"), n: TypeBox::Type.integer}),
      TypeBox::Type.object({t: TypeBox::Type.literal("pong"), n: TypeBox::Type.integer}),
      TypeBox::Type.object({t: TypeBox::Type.literal("bye"), reason: TypeBox::Type.optional(TypeBox::Type.string)}),
      TypeBox::Type.object({t: TypeBox::Type.literal("root_end"), rootId: NAME}),
      TypeBox::Type.object({t: TypeBox::Type.literal("invalidate"), pattern: TypeBox::Type.record(TypeBox::Type.string, TypeBox::Type.unknown)}),
      TypeBox::Type.object({
        t:           TypeBox::Type.literal("prepare"),
        reload:      RELOAD,
        codeVersion: TypeBox::Type.integer(minimum: 1),
        plugins:     TypeBox::Type.array(TypeBox::Type.string),
        options:     RELOAD_OPTIONS,
      }),
      TypeBox::Type.object({
        t:      TypeBox::Type.literal("vote"),
        reload: RELOAD,
        error:  TypeBox::Type.optional(ERROR),
        report: TypeBox::Type.optional(RELOAD_REPORT),
      }),
      TypeBox::Type.object({t: TypeBox::Type.literal("commit"), reload: RELOAD}),
      TypeBox::Type.object({t: TypeBox::Type.literal("retire"), codeVersion: TypeBox::Type.integer(minimum: 1)}),
      TypeBox::Type.object({t: TypeBox::Type.literal("abort"), reload: RELOAD}),
    ])

    def self.frame?(frame : Frame) : Bool
      TypeBox::Value.check(FRAME_SCHEMA, JSON::Any.new(frame.fields))
    end

    def self.to_error(error : Exception) : JSON::Any
      fields = {} of String => JSON::Any
      if error.is_a?(ChordError)
        fields["code"] = JSON::Any.new(error.code.label)
        fields["message"] = JSON::Any.new(error.message || "")
        error.reason.try { |reason| fields["reason"] = JSON::Any.new(reason) }
      else
        fields["code"] = JSON::Any.new(ErrorCode::Unavailable.label)
        fields["message"] = JSON::Any.new(error.message || error.class.name)
      end
      JSON::Any.new(fields)
    end

    def self.from_error(error : JSON::Any) : ChordError
      code = ErrorCode.parse?(error["code"]?.try(&.as_s?) || "") || ErrorCode::Unavailable
      message = (error["message"]?.try(&.as_s?) || "").sub(/^[a-z_]+(\/[a-z_]+)?: /, "")
      ChordError.new(code, message, reason: error["reason"]?.try(&.as_s?))
    end

    def self.encode_object(frame : Frame, compress : Bool) : String
      field = frame.payload_field
      packed = field ? packed_payload(frame, field, compress) : nil
      return frame.to_json unless field && packed
      JSON.build do |builder|
        builder.object do
          frame.fields.each { |key, value| builder.field(key) { value.to_json(builder) } unless key == field }
          builder.field("z") do
            builder.array do
              builder.string(field)
              builder.string(Base64.strict_encode(packed.bytes))
            end
          end
        end
      end
    end

    def self.decode_object(message : JSON::Any) : Frame
      fields = message.as_h? || raise ArgumentError.new("not a frame")
      raise ArgumentError.new("not a frame") unless fields["t"]?.try(&.as_s?)
      z = fields["z"]?
      return Frame.new(fields) unless z
      parts = z.as_a?
      field = parts.try(&.[0]?).try(&.as_s?)
      data = parts.try(&.[1]?).try(&.as_s?)
      raise ArgumentError.new("bad packed payload") unless field && data && Frame::PAYLOAD_FIELDS.includes?(field)
      rest = fields.dup
      rest.delete("z")
      Frame.new(rest, Packed.new(field, Base64.decode(data)))
    end

    def self.parse(text : String) : Frame
      decode_object(JSON.parse(text))
    end

    def self.encode_message(frame : Frame, compress : Bool) : String | Bytes
      field = frame.payload_field
      return frame.to_json unless field
      packed = packed_payload(frame, field, compress)
      return frame.to_json unless packed
      envelope = frame.fields.dup
      envelope.delete(field)
      envelope["z"] = JSON::Any.new(field)
      head = envelope.to_json.to_slice
      message = Bytes.new(4 + head.size + packed.bytes.size)
      IO::ByteFormat::BigEndian.encode(head.size.to_u32, message[0, 4])
      head.copy_to(message[4, head.size])
      packed.bytes.copy_to(message[4 + head.size, packed.bytes.size])
      message
    end

    def self.decode_message(data : Bytes) : Frame
      raise ArgumentError.new("bad envelope") if data.size < 4
      length = IO::ByteFormat::BigEndian.decode(UInt32, data[0, 4]).to_i
      raise ArgumentError.new("bad envelope") if 4 + length > data.size
      envelope = JSON.parse(String.new(data[4, length])).as_h? || raise ArgumentError.new("bad envelope")
      field = envelope["z"]?.try(&.as_s?)
      raise ArgumentError.new("bad packed payload") unless field && Frame::PAYLOAD_FIELDS.includes?(field)
      raise ArgumentError.new("not a frame") unless envelope["t"]?.try(&.as_s?)
      envelope.delete("z")
      Frame.new(envelope, Packed.new(field, data[4 + length, data.size - 4 - length].dup))
    end

    def self.inflate_message(data : Bytes) : String
      decode_message(data).to_json
    end

    private def self.packed_payload(frame : Frame, field : String, compress : Bool) : Packed?
      if packed = frame.packed
        return packed if packed.field == field
      end
      return unless compress
      value = frame.fields[field]?
      return unless value
      json = value.to_json
      json.bytesize > PACK_THRESHOLD ? Packed.deflate(field, json) : nil
    end
  end
end
