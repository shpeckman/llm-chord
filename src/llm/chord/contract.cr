# src/llm/chord/contract.cr
module LLM::Chord
  struct MethodSpec
    getter args : TypeBox::Schema?
    getter result : TypeBox::Schema?

    def initialize(@args : TypeBox::Schema? = nil, @result : TypeBox::Schema? = nil); end
  end

  struct OpaqueSpec
    getter id : String

    def initialize(@id : String); end
  end

  alias Member = MethodSpec | OpaqueSpec | TypeBox::Schema

  abstract struct Placement
    abstract def text : String
    abstract def placed_on?(host_name : String) : Bool
    abstract def resolve(type_name : String, input : JSON::Any?) : String
    abstract def json : JSON::Any

    def to_json(builder : JSON::Builder) : Nil
      json.to_json(builder)
    end
  end

  struct HostNamed < Placement
    getter name : String

    def initialize(@name : String); end

    def text : String
      @name
    end

    def placed_on?(host_name : String) : Bool
      @name == host_name
    end

    def resolve(type_name : String, input : JSON::Any?) : String
      @name
    end

    def json : JSON::Any
      JSON::Any.new({"name" => JSON::Any.new(@name)})
    end
  end

  struct HostFamily < Placement
    getter prefix : String
    getter key : String

    def initialize(@prefix : String, @key : String); end

    def text : String
      "#{@prefix}<#{@key}>"
    end

    def placed_on?(host_name : String) : Bool
      host_name.starts_with?(@prefix) && host_name.size > @prefix.size
    end

    def resolve(type_name : String, input : JSON::Any?) : String
      value = input.try(&.as_h?).try(&.[@key]?).try(&.as_s?)
      raise Chord.invalid("placement", "#{type_name}: input field #{@key} names no host") if value.nil? || value.empty?
      @prefix + value
    end

    def json : JSON::Any
      JSON::Any.new({"prefix" => JSON::Any.new(@prefix), "key" => JSON::Any.new(@key)})
    end
  end

  record VariantDef, state : Hash(String, Member) = {} of String => Member, methods : Hash(String, Member) = {} of String => Member

  record RemoteDef, version : Int32, input : TypeBox::Schema, host : Placement, variants : Hash(String, VariantDef)

  record LocalDef, version : Int32, input : TypeBox::Schema, members : Hash(String, Member) = {} of String => Member

  struct MemberDescription
    getter json : JSON::Any

    def initialize(@json : JSON::Any); end

    def kind : String
      @json["kind"]?.try(&.as_s?) || ""
    end

    def args : JSON::Any?
      @json["args"]?
    end

    def result : JSON::Any?
      @json["result"]?
    end

    def schema : JSON::Any?
      @json["schema"]?
    end

    def id : String?
      @json["id"]?.try(&.as_s?)
    end

    def method? : Bool
      kind == "method"
    end

    def state? : Bool
      kind == "state"
    end

    def opaque? : Bool
      kind == "opaque"
    end
  end

  class Description
    getter json : JSON::Any

    def initialize(@json : JSON::Any); end

    def name : String
      @json["name"]?.try(&.as_s?) || ""
    end

    def scope : String
      @json["scope"]?.try(&.as_s?) || ""
    end

    def version : Int32
      @json["version"]?.try { |value| TypeBox::Guard.to_f(value).to_i } || 0
    end

    def input : JSON::Any
      @json["input"]? || JSON::Any.new({} of String => JSON::Any)
    end

    def host_json : JSON::Any?
      @json["host"]?
    end

    def host : Placement?
      fields = host_json.try(&.as_h?)
      return unless fields
      if name = fields["name"]?.try(&.as_s?)
        HostNamed.new(name)
      elsif (prefix = fields["prefix"]?.try(&.as_s?)) && (key = fields["key"]?.try(&.as_s?))
        HostFamily.new(prefix, key)
      end
    end

    def variants : Hash(String, Hash(String, MemberDescription))
      result = {} of String => Hash(String, MemberDescription)
      @json["variants"]?.try(&.as_h?).try &.each do |kind, members|
        result[kind] = members.as_h?.try(&.transform_values { |member| MemberDescription.new(member) }) || {} of String => MemberDescription
      end
      result
    end

    def placement_text : String
      host.try(&.text) || "(local)"
    end

    def fingerprint : String
      Schema.hash64(Schema.canonical_json(@json))
    end

    def to_json(builder : JSON::Builder) : Nil
      @json.to_json(builder)
    end
  end

  abstract class Contract
    getter name : String
    getter version : Int32
    getter input : TypeBox::Schema
    getter description : Description
    getter fingerprint : String

    def initialize(@name : String, @version : Int32, @input : TypeBox::Schema, @description : Description)
      @fingerprint = @description.fingerprint
    end

    abstract def scope : String

    def remote? : Bool
      scope == "remote"
    end

    def local? : Bool
      scope == "local"
    end

    def self.from_description(json : JSON::Any) : Contract
      description = Description.new(json)
      name = json["name"]?.try(&.as_s?)
      scope = json["scope"]?.try(&.as_s?)
      version = json["version"]?
      host = description.host_json
      if name.nil? || (scope != "remote" && scope != "local") || !TypeBox::Guard.integer?(version) || (scope == "remote") != !host.nil?
        raise ChordError.new(ErrorCode::Invalid, "malformed contract token", reason: "token")
      end
      input = TypeBox::Schema.from_json(description.input)
      if scope == "remote"
        placement = description.host || raise ChordError.new(ErrorCode::Invalid, "malformed contract token", reason: "token")
        RemoteContract.new(name, description.version, input, description, RemoteDef.new(description.version, input, placement, {} of String => VariantDef))
      else
        LocalContract.new(name, description.version, input, description, LocalDef.new(description.version, input))
      end
    end
  end

  class RemoteContract < Contract
    getter definition : RemoteDef

    def initialize(name : String, version : Int32, input : TypeBox::Schema, description : Description, @definition : RemoteDef)
      super(name, version, input, description)
    end

    def scope : String
      "remote"
    end

    def host : Placement
      @definition.host
    end
  end

  class LocalContract < Contract
    getter definition : LocalDef

    def initialize(name : String, version : Int32, input : TypeBox::Schema, description : Description, @definition : LocalDef)
      super(name, version, input, description)
    end

    def scope : String
      "local"
    end
  end

  LOCAL_VARIANT    = ""
  RESERVED_MEMBERS = ::Set{"variant", "status", "ready", "shape", "error", "onShape", "onStatus", "release", "then", "contract"}
  OPAQUE_ID        = "^[^@\\s]+@\\d+$"

  SCHEMA_OBJECT = TypeBox::Type.unsafe(TypeBox::Type.object)

  MEMBER_DESCRIPTION_SCHEMA = TypeBox::Type.union([
    TypeBox::Type.object({
      kind:   TypeBox::Type.literal("method"),
      args:   TypeBox::Type.optional(SCHEMA_OBJECT),
      result: TypeBox::Type.optional(SCHEMA_OBJECT),
    }),
    TypeBox::Type.object({kind: TypeBox::Type.literal("state"), schema: SCHEMA_OBJECT}),
    TypeBox::Type.object({kind: TypeBox::Type.literal("opaque"), id: TypeBox::Type.string}),
  ])

  PLACEMENT_SCHEMA = TypeBox::Type.union([
    TypeBox::Type.object({name: TypeBox::Type.string(minLength: 1)}, additionalProperties: false),
    TypeBox::Type.object({prefix: TypeBox::Type.string(minLength: 1), key: TypeBox::Type.string(minLength: 1)}, additionalProperties: false),
  ])

  DESCRIPTION_SCHEMA = TypeBox::Type.object({
    name:     TypeBox::Type.string(minLength: 1),
    scope:    TypeBox::Type.union([TypeBox::Type.literal("remote"), TypeBox::Type.literal("local")]),
    version:  TypeBox::Type.integer,
    input:    SCHEMA_OBJECT,
    host:     TypeBox::Type.optional(PLACEMENT_SCHEMA),
    variants: TypeBox::Type.record(TypeBox::Type.string, TypeBox::Type.record(TypeBox::Type.string, MEMBER_DESCRIPTION_SCHEMA)),
  })

  def self.method(args : TypeBox::Schema? = nil, result : TypeBox::Schema? = nil) : MethodSpec
    MethodSpec.new(args, result)
  end

  def self.opaque(id : String) : OpaqueSpec
    raise ArgumentError.new("opaque id must be name@version: #{id}") unless TypeBox::JsRegex.test(OPAQUE_ID, id)
    OpaqueSpec.new(id)
  end

  def self.host_named(name : String) : HostNamed
    raise ArgumentError.new("hostNamed needs a host name") if name.empty?
    HostNamed.new(name)
  end

  def self.host_family(prefix : String, key : String) : HostFamily
    raise ArgumentError.new("hostFamily needs a host-name prefix") if prefix.empty?
    raise ArgumentError.new("hostFamily needs an input field name") if key.empty?
    HostFamily.new(prefix, key)
  end

  def self.resolve_host(type_name : String, placement : Placement, input : JSON::Any?) : String
    placement.resolve(type_name, input)
  end

  def self.placed_on?(placement : Placement, host_name : String) : Bool
    placement.placed_on?(host_name)
  end

  def self.placement_text(placement : Placement) : String
    placement.text
  end

  def self.variant(state = NamedTuple.new, methods = NamedTuple.new) : VariantDef
    VariantDef.new(members(state), members(methods))
  end

  def self.remote(name : String, *, version : Int32, input : TypeBox::Schema, host : Placement, variants) : RemoteContract
    remote(name, RemoteDef.new(version, input, host, variant_map(variants)))
  end

  def self.remote(name : String, definition : RemoteDef) : RemoteContract
    check_header(name, definition.version)
    unless TypeBox::Value.check(PLACEMENT_SCHEMA, definition.host.json)
      raise ArgumentError.new("remote contract #{name} needs `host`: hostNamed(…) or hostFamily(…)")
    end
    raise ArgumentError.new("remote contract #{name} has no variants") if definition.variants.empty?
    variants = {} of String => JSON::Any
    definition.variants.each do |kind, variant|
      described = {} of String => JSON::Any
      variant.state.each { |key, member| described[key] = describe_member(key, member, "remote") }
      variant.methods.each do |key, member|
        raise ArgumentError.new("member #{key} is both state and method in #{name}.#{kind}") if described.has_key?(key)
        described[key] = describe_member(key, member, "remote")
        raise ArgumentError.new("methods.#{key} is not a method()") unless member.is_a?(MethodSpec)
      end
      variants[kind] = JSON::Any.new(described)
    end
    description = Description.new(JSON::Any.new({
      "name"     => JSON::Any.new(name),
      "scope"    => JSON::Any.new("remote"),
      "version"  => JSON::Any.new(definition.version.to_i64),
      "input"    => definition.input.json,
      "host"     => definition.host.json,
      "variants" => JSON::Any.new(variants),
    }))
    RemoteContract.new(name, definition.version, definition.input, description, definition)
  end

  def self.local(name : String, *, version : Int32, input : TypeBox::Schema, members = NamedTuple.new) : LocalContract
    local(name, LocalDef.new(version, input, members(members)))
  end

  def self.local(name : String, definition : LocalDef) : LocalContract
    check_header(name, definition.version)
    described = {} of String => JSON::Any
    definition.members.each { |key, member| described[key] = describe_member(key, member, "local") }
    description = Description.new(JSON::Any.new({
      "name"     => JSON::Any.new(name),
      "scope"    => JSON::Any.new("local"),
      "version"  => JSON::Any.new(definition.version.to_i64),
      "input"    => definition.input.json,
      "variants" => JSON::Any.new({LOCAL_VARIANT => JSON::Any.new(described)}),
    }))
    LocalContract.new(name, definition.version, definition.input, description, definition)
  end

  def self.contract_from_description(json : JSON::Any) : Contract
    Contract.from_description(json)
  end

  def self.coverage(provider : Description, consumer : Description) : String?
    return "different type" if provider.name != consumer.name || provider.scope != consumer.scope
    return "host" unless same_placement?(provider, consumer)
    return "input" unless Schema.fits?(consumer.input, provider.input)
    offered_variants = provider.variants
    consumer.variants.each do |kind, wanted_members|
      offered_members = offered_variants[kind]?
      return "variant #{kind} missing" unless offered_members
      wanted_members.each do |name, wanted|
        offered = offered_members[name]?
        return "#{kind}.#{name} missing or of another kind" if offered.nil? || offered.kind != wanted.kind
        if reason = member_coverage(kind, name, offered, wanted)
          return reason
        end
      end
    end
  end

  def self.bind(provider : Contract, accepts : Hash(Int32, A), consumer : Contract) : A? forall A
    return unless needs_adapter?(provider, consumer)
    accepts[consumer.version]? || raise no_adapter(provider, consumer)
  end

  def self.bind(provider : Contract, accepts : Nil, consumer : Contract) : Nil
    raise no_adapter(provider, consumer) if needs_adapter?(provider, consumer)
  end

  def self.takes_no_args?(contract : Contract, name : String) : Bool
    contract.description.variants.each_value do |members|
      member = members[name]?
      return member.args.nil? if member && member.method?
    end
    false
  end

  private def self.needs_adapter?(provider : Contract, consumer : Contract) : Bool
    return false if provider.fingerprint == consumer.fingerprint
    unless same_placement?(provider.description, consumer.description)
      raise ChordError.new(ErrorCode::ContractMismatch,
        "#{provider.name} lives on #{provider.description.placement_text}, the consumer expects #{consumer.description.placement_text}")
    end
    return true unless provider.version == consumer.version
    reason = coverage(provider.description, consumer.description)
    return false unless reason
    raise ChordError.new(ErrorCode::ContractMismatch,
      "#{provider.name}@#{provider.version} does not cover the consumer's description (#{reason}); forgotten version bump?")
  end

  private def self.no_adapter(provider : Contract, consumer : Contract) : ChordError
    ChordError.new(ErrorCode::ContractMismatch,
      "#{provider.name}: provider version #{provider.version}, consumer version #{consumer.version}, no accepts adapter")
  end

  private def self.member_coverage(kind : String, name : String, offered : MemberDescription, wanted : MemberDescription) : String?
    if offered.method? && wanted.method?
      method_coverage(offered, wanted).try { |part| "#{kind}.#{name} #{part}" }
    elsif offered.state? && wanted.state?
      "#{kind}.#{name} state" unless Schema.fits?(offered.schema, wanted.schema)
    elsif offered.opaque? && wanted.opaque? && offered.id != wanted.id
      "#{kind}.#{name} opaque #{offered.id} != #{wanted.id}"
    end
  end

  private def self.method_coverage(offered : MemberDescription, wanted : MemberDescription) : String?
    wanted_args = wanted.args
    offered_args = offered.args
    return "arguments" if wanted_args.nil? != offered_args.nil?
    return "arguments" if wanted_args && offered_args && !Schema.fits?(wanted_args, offered_args)
    wanted_result = wanted.result
    return unless wanted_result
    offered_result = offered.result
    "result" if offered_result.nil? || !Schema.fits?(offered_result, wanted_result)
  end

  private def self.same_placement?(left : Description, right : Description) : Bool
    Schema.canonical_json(left.host_json || JSON::Any.new(nil)) == Schema.canonical_json(right.host_json || JSON::Any.new(nil))
  end

  private def self.check_header(name : String, version : Int32) : Nil
    raise ArgumentError.new("contract name is empty") if name.empty?
    raise ArgumentError.new("contract version must be a positive integer") if version < 1
  end

  private def self.describe_member(name : String, member : Member, scope : String) : JSON::Any
    raise ArgumentError.new("member name is reserved: #{name}") if RESERVED_MEMBERS.includes?(name)
    fields = {} of String => JSON::Any
    case member
    when MethodSpec
      fields["kind"] = JSON::Any.new("method")
      member.args.try { |args| fields["args"] = args.json }
      member.result.try { |result| fields["result"] = result.json }
    when OpaqueSpec
      raise ArgumentError.new("remote contracts cannot expose opaque members: #{name}") if scope == "remote"
      fields["kind"] = JSON::Any.new("opaque")
      fields["id"] = JSON::Any.new(member.id)
    else
      fields["kind"] = JSON::Any.new("state")
      fields["schema"] = member.json
    end
    JSON::Any.new(fields)
  end

  private def self.members(source : NamedTuple | Hash) : Hash(String, Member)
    result = {} of String => Member
    source.each { |key, member| result[key.to_s] = member.as(Member) }
    result
  end

  private def self.variant_map(source : NamedTuple | Hash) : Hash(String, VariantDef)
    result = {} of String => VariantDef
    source.each { |key, variant| result[key.to_s] = variant.as(VariantDef) }
    result
  end
end
