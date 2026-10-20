# src/llm/chord/connection.cr
module LLM::Chord
  DEFAULT_WINDOW  = 256_i64 * 1024
  PENDING_WINDOWS = 4

  enum Role
    Upstream
    Downstream
  end

  enum PeerKind
    Host
    Client

    def label : String
      to_s.downcase
    end
  end

  alias MismatchHandler = Proc(Int32, Int32?, Nil)

  struct LinkOptions
    getter ping_interval : Time::Span
    getter ping_timeout : Time::Span
    getter window : Int64?
    getter pending_cap : Int64?
    getter on_protocol_mismatch : MismatchHandler?

    def initialize(@ping_interval : Time::Span = 15.seconds, @ping_timeout : Time::Span = 45.seconds,
                   window : Int? = DEFAULT_WINDOW, pending_cap : Int? = nil,
                   @on_protocol_mismatch : MismatchHandler? = nil)
      @window = window.try(&.to_i64)
      @pending_cap = pending_cap.try(&.to_i64)
    end
  end

  record Peer, kind : PeerKind, name : String?

  record Overflow, resend : Proc(Nil)? = nil, resync : Proc(Nil)? = nil

  abstract class Slot
    getter hold : Int64

    def initialize(@hold : Int64); end
  end

  class UnitSlot < Slot
    getter flush : Proc(Nil)

    def initialize(hold : Int64, @flush : Proc(Nil))
      super(hold)
    end
  end

  class StateSlot < Slot
    getter m : String
    property base : Frame? = nil
    property ops = [] of JSON::Any
    property size = 0_i64
    property? lazy : Bool
    getter overflow : Overflow

    def initialize(hold : Int64, @m : String, @lazy : Bool, @overflow : Overflow)
      super(hold)
    end
  end

  class Feed
    property unsubscribe : Proc(Nil) = -> { }
    property encoder = Delta::Encoder.new
    property buffer : Array(StateEvent)? = [] of StateEvent
  end

  abstract class Served
  end

  class ServedLocal < Served
    getter id : Int64
    getter ref : LocalRef
    getter principal : JSON::Any
    getter origin : String?
    property? wants_state : Bool
    getter? again : Bool
    property? unit_sent = false
    getter feeds = {} of String => Feed

    def initialize(@id : Int64, @ref : LocalRef, @principal : JSON::Any, @origin : String?, @wants_state : Bool, @again : Bool); end
  end

  class ServedRelay < Served
    getter relay : RelayRef

    def initialize(@relay : RelayRef); end
  end

  class RelayRef
    getter origin : Connection
    getter frame : Frame
    getter principal : JSON::Any
    getter origin_tag : String?
    getter generation : Int32
    getter down : Connection? = nil
    getter down_id = 0_i64
    getter? closed = false
    getter? state_wanted : Bool
    getter awaiting = ::Set(String).new
    getter calls = {} of Int64 => RelayCall
    @urgent : ::Set(String)? = nil
    @shaped = false
    @waiters = [] of Future(Connection)

    def initialize(@origin : Connection, @frame : Frame, @principal : JSON::Any, @origin_tag : String?)
      @state_wanted = @frame["state"]? != JSON::Any.new(false)
      @generation = @origin.generation
    end

    def origin_id : Int64
      @frame.int("id")
    end

    def client? : Bool
      !@origin_tag.nil?
    end

    def current? : Bool
      !@closed && @origin.open? && @origin.generation == @generation
    end

    def ready_future : Future(Connection)
      future = Future(Connection).new
      if @closed
        future.reject(ChordError.new(ErrorCode::Gone, "relayed hold closed"))
      elsif down = @down
        future.resolve(down)
      else
        @waiters << future
      end
      future
    end

    protected def open(down : Connection) : Nil
      return if @closed
      @down = down
      @down_id = down.next_id
      down.relayed_refs[@down_id] = self
      fields = {
        "t"         => JSON::Any.new("hold"),
        "id"        => JSON::Any.new(@down_id),
        "at"        => @frame["at"],
        "token"     => @frame["token"],
        "input"     => @frame["input"],
        "principal" => @principal,
      }
      @origin_tag.try { |tag| fields["origin"] = JSON::Any.new(tag) }
      fields["state"] = JSON::Any.new(false) unless @state_wanted
      fields["again"] = JSON::Any.new(true) if @frame["again"]? == JSON::Any.new(true)
      down.send(Frame.new(fields))
      waiters = @waiters.dup
      @waiters.clear
      waiters.each(&.resolve(down))
    end

    protected def want_state(wanted : Bool) : Nil
      return if @closed || wanted == @state_wanted
      @state_wanted = wanted
      unless wanted
        @origin.drop_hold_state(origin_id)
        @awaiting.clear
      end
      @down.try &.send(Frame.build(wanted ? "sub" : "unsub", hold: @down_id))
    end

    protected def resync(m : String) : Nil
      return if @closed
      @awaiting << m
      @down.try &.send(Frame.build("resync", hold: @down_id, m: m))
    end

    protected def shape(frame : Frame) : Nil
      return if @closed
      unless @shaped
        @shaped = true
        @urgent = frame["state"].as_a.map(&.as_s).to_set unless @frame["again"]? == JSON::Any.new(true)
      end
      @origin.send(frame.with("id", JSON::Any.new(origin_id)))
    end

    protected def state(frame : Frame) : Nil
      return if @closed
      m = frame.string("m")
      if @awaiting.includes?(m)
        return if frame.string("as") == "ops"
        @awaiting.delete(m)
      end
      relayed = frame.with("hold", JSON::Any.new(origin_id))
      if @urgent.try(&.delete(m))
        @origin.send(relayed)
        return
      end
      @origin.send_state(relayed, Overflow.new(resync: resyncer(m)))
    end

    protected def close(error : Exception, release_down : Bool, notify : Bool) : Nil
      return if @closed
      @closed = true
      @calls.values.each(&.cancel(error, release_down))
      @origin.drop_hold_state(origin_id)
      @origin.served.delete(origin_id) if @origin.served[origin_id]?.as?(ServedRelay).try(&.relay.same?(self))
      if down = @down
        down.relayed_refs.delete(@down_id)
        down.send(Frame.build("release", id: @down_id)) if release_down
      end
      waiters = @waiters.dup
      @waiters.clear
      waiters.each(&.reject(error))
      @origin.send(Frame.build("gone", id: origin_id, error: Wire.to_error(error))) if notify
    end

    private def resyncer(m : String) : Proc(Nil)
      -> { resync(m); nil }
    end
  end

  class RelayCall
    getter relay : RelayRef
    getter origin_id : Int64
    getter down_id : Int64
    @settled = false

    def initialize(@relay : RelayRef, @origin_id : Int64, @down_id : Int64, @pending : Future(Frame))
      @relay.calls[@origin_id] = self
      @relay.down.try &.relayed_calls.[]=(@down_id, self)
    end

    protected def finish(error : Exception?, result : Frame? = nil) : Nil
      return if @settled
      @settled = true
      @relay.calls.delete(@origin_id)
      @relay.down.try &.relayed_calls.delete(@down_id)
      if error
        @pending.reject(error)
      else
        @pending.resolve(result.not_nil!)
      end
    end

    protected def cancel(error : Exception, forward : Bool) : Nil
      return if @settled
      @relay.down.try &.send(Frame.build("cancel", id: @down_id)) if forward
      finish(error)
    end
  end

  class Connection
    getter host : Host
    getter link : Link
    getter role : Role
    getter peer : Peer
    getter origin_id : String?
    property principal : JSON::Any
    getter restamp : Proc(JSON::Any, JSON::Any?)?
    getter generation = 0
    getter peer_code_version : Int32? = nil
    getter? synced : Bool
    getter remotes = {} of Int64 => RemoteBinding
    getter calls = {} of Int64 => Future(Frame)
    getter served = {} of Int64 => Served
    getter incoming = {} of Int64 => AbortController
    getter relayed_refs = {} of Int64 => RelayRef
    getter relayed_calls = {} of Int64 => RelayCall
    @parent_name : String? = nil
    @sync_waiters = [] of Future(Nil)
    @next_id = 1_i64
    @last_seen : Time::Instant = Time.instant
    @max_calls : Int32?
    @window : Int64?
    @pending_cap : Int64?
    @peer_acks : Bool? = nil
    @sent = 0_i64
    @acked = 0_i64
    @unacked = Deque(Int64).new
    @unacked_bytes = 0_i64
    @pending = {} of String => Slot
    @pending_bytes = 0_i64
    @received = 0_i64
    @ack_scheduled = false
    @on_protocol_mismatch : MismatchHandler?
    @mismatched = false

    def initialize(@host : Host, @link : Link, @role : Role, @principal : JSON::Any, @peer : Peer,
                   options : LinkOptions, @origin_id : String? = nil, @restamp : Proc(JSON::Any, JSON::Any?)? = nil,
                   @max_calls : Int32? = nil)
      @synced = !(@role.downstream? && @peer.kind.host?)
      @window = options.window
      @pending_cap = options.pending_cap || options.window.try { |window| window * PENDING_WINDOWS }
      @on_protocol_mismatch = options.on_protocol_mismatch
      @link.on_close { |reason| closed(reason) }
      @link.receive { |frame| receive(frame) }
      send(Frame.build("hello", protocol: PROTOCOL_VERSION, name: @host.name, kind: @host.kind.label,
        codeVersion: @host.code_version, acks: true))
      start_pinger(options.ping_interval, options.ping_timeout) unless @link.closed?
    end

    def open? : Bool
      !@link.closed?
    end

    def name : String?
      @role.upstream? ? @parent_name : @peer.name
    end

    def waiting : NamedTuple(slots: Int32, bytes: Int64)
      {slots: @pending.size, bytes: @pending_bytes}
    end

    def send(frame : Frame) : Nil
      size = (@link.send(frame) || 0).to_i64
      return if @peer_acks == false
      @sent += 1
      @unacked << size
      @unacked_bytes += size
    end

    protected def next_id : Int64
      id = @next_id
      @next_id += 1
      id
    end

    protected def when_synced : Nil
      raise ChordError.new(ErrorCode::Unavailable, "link to #{name || "peer"} closed") unless open?
      return if @synced
      waiter = Future(Nil).new
      @sync_waiters << waiter
      waiter.wait
    end

    protected def mark_synced(code_version : Int32) : Nil
      @peer_code_version = code_version
      @synced = true
      waiters = @sync_waiters.dup
      @sync_waiters.clear
      waiters.each(&.resolve(nil))
    end

    protected def revoke(following : JSON::Any?) : Nil
      @generation += 1
      error = ChordError.new(ErrorCode::Gone, "principal invalidated")
      @served.values.each { |served| served.as?(ServedRelay).try &.relay.close(error, true, true) }
      if following
        @principal = following
      else
        @link.close("principal invalidated")
      end
    end

    protected def send_state(frame : Frame, overflow : Overflow) : Nil
      key = Connection.state_key(frame.int("hold"), frame.string("m"))
      slot = @pending[key]?
      if slot.nil? && !full?
        send(frame)
        return
      end
      return if slot.is_a?(UnitSlot)
      state = slot.as?(StateSlot)
      unless state
        state = StateSlot.new(frame.int("hold"), frame.string("m"), false, overflow)
        @pending[key] = state
      end
      unless frame.string("as") == "ops"
        @pending_bytes -= state.size
        state.base = frame
        state.ops = [] of JSON::Any
        state.size = 0
        state.lazy = false
        return
      end
      return if state.lazy?
      ops = frame["ops"]?.try(&.as_a) || [] of JSON::Any
      size = ops.to_json.bytesize.to_i64
      if (cap = @pending_cap) && @pending_bytes + size > cap
        make_room(size, state, cap)
      end
      return if state.lazy? || !@pending[key]?.same?(state)
      state.ops.concat(ops)
      state.size += size
      @pending_bytes += size
    end

    protected def drop_state(hold : Int64, m : String) : Nil
      key = Connection.state_key(hold, m)
      slot = @pending[key]?.as?(StateSlot)
      return unless slot
      @pending_bytes -= slot.size
      @pending.delete(key)
    end

    protected def drop_hold_state(hold : Int64) : Nil
      @pending.to_a.each do |(key, slot)|
        next unless slot.hold == hold
        @pending_bytes -= slot.size if slot.is_a?(StateSlot)
        @pending.delete(key)
      end
    end

    protected def hold(binding : RemoteBinding, again : Bool) : Int64
      id = next_id
      @remotes[id] = binding
      binding.bound(self, id)
      fields = {
        "t"     => JSON::Any.new("hold"),
        "id"    => JSON::Any.new(id),
        "at"    => JSON::Any.new(binding.at),
        "token" => binding.contract.description.json,
        "input" => binding.input,
      }
      binding.principal.try { |principal| fields["principal"] = principal }
      fields["state"] = JSON::Any.new(false) unless binding.state_on?
      fields["again"] = JSON::Any.new(true) if again
      send(Frame.new(fields))
      id
    end

    protected def release(id : Int64) : Nil
      @remotes.delete(id)
      send(Frame.build("release", id: id))
    end

    protected def want_state(hold : Int64, wanted : Bool) : Nil
      send(Frame.build(wanted ? "sub" : "unsub", hold: hold)) if @remotes.has_key?(hold)
    end

    protected def call(hold : Int64, member : String, args : JSON::Any?, root_id : String, code_version : Int32,
                       signal : AbortSignal) : JSON::Any?
      raise ChordError.new(ErrorCode::Aborted, "call aborted") if signal.aborted?
      id = next_id
      pending = Future(Frame).new
      @calls[id] = pending
      carried = @host.kind.host?
      @host.root_sent(root_id, self) if carried
      fields = {
        "t"      => JSON::Any.new("call"),
        "id"     => JSON::Any.new(id),
        "hold"   => JSON::Any.new(hold),
        "member" => JSON::Any.new(member),
      }
      args.try { |value| fields["args"] = value }
      if carried
        fields["root"] = JSON::Any.new({"rootId" => JSON::Any.new(root_id), "codeVersion" => JSON::Any.new(code_version.to_i64)})
      end
      send(Frame.new(fields))
      if pending.wait([signal], nil).aborted?
        @calls.delete(id)
        send(Frame.build("cancel", id: id))
        raise ChordError.new(ErrorCode::Aborted, "call aborted", cause: signal.reason)
      end
      result = pending.wait
      if error = result["error"]?
        raise Wire.from_error(error)
      end
      result.payload
    end

    private def full? : Bool
      window = @window
      @peer_acks == true && !window.nil? && @unacked_bytes >= window
    end

    private def make_room(size : Int64, current : StateSlot, cap : Int64) : Nil
      @pending.values.each do |slot|
        return if @pending_bytes + size <= cap
        drop(slot) if slot.is_a?(StateSlot) && !slot.same?(current) && slot.size > 0
      end
      drop(current) if @pending_bytes + size > cap
    end

    private def drop(slot : StateSlot) : Nil
      @pending_bytes -= slot.size
      slot.base = nil
      slot.ops = [] of JSON::Any
      slot.size = 0
      if slot.overflow.resend
        slot.lazy = true
        return
      end
      @pending.delete(Connection.state_key(slot.hold, slot.m))
      slot.overflow.resync.try &.call
    end

    private def reset_later(hold : Int64, m : String, resend : Proc(Nil)) : Nil
      key = Connection.state_key(hold, m)
      slot = @pending[key]?
      return if slot.is_a?(UnitSlot)
      if state = slot.as?(StateSlot)
        @pending_bytes -= state.size
        state.base = nil
        state.ops = [] of JSON::Any
        state.size = 0
        state.lazy = true
      else
        @pending[key] = StateSlot.new(hold, m, true, Overflow.new(resend: resend))
      end
      flush
    end

    private def queue_unit(hold : Int64, flush : Proc(Nil)) : Nil
      key = Connection.unit_key(hold)
      @pending[key] = UnitSlot.new(hold, flush) unless @pending.has_key?(key)
      self.flush
    end

    private def on_ack(n : Int64) : Nil
      if @peer_acks != true || n < @acked || n > @sent
        violation("ack #{n} outside #{@acked}..#{@sent}")
        return
      end
      (n - @acked).times { @unacked_bytes -= @unacked.shift }
      @acked = n
      flush
    end

    private def flush : Nil
      until full?
        entry = @pending.first?
        return unless entry
        key, slot = entry
        @pending.delete(key)
        case slot
        when UnitSlot
          slot.flush.call
        when StateSlot
          @pending_bytes -= slot.size
          if slot.lazy?
            slot.overflow.resend.try &.call
            next
          end
          slot.base.try { |base| send(base) }
          unless slot.ops.empty?
            send(Frame.state(slot.hold, slot.m, "ops", ops: slot.ops))
          end
        end
      end
    end

    private def schedule_ack : Nil
      return if @peer_acks != true || @ack_scheduled || !open?
      @ack_scheduled = true
      spawn { send_ack }
    end

    private def send_ack : Nil
      @ack_scheduled = false
      @link.send(Frame.build("ack", n: @received)) if open?
    end

    private def start_pinger(interval : Time::Span, timeout : Time::Span) : Nil
      spawn { ping_loop(interval, timeout) }
    end

    private def ping_loop(interval : Time::Span, timeout : Time::Span) : Nil
      n = 0_i64
      loop do
        sleep interval
        break unless open?
        if Time.instant - @last_seen > timeout
          @link.close("ping timeout")
          break
        end
        n += 1
        send(Frame.build("ping", n: n))
      end
    end

    private def protocol_mismatch(peer : Int32?, close : Bool = true) : Nil
      return if @mismatched
      @mismatched = true
      begin
        @on_protocol_mismatch.try &.call(PROTOCOL_VERSION, peer)
      rescue error
        @host.report(error)
      end
      @link.close("protocol-version #{PROTOCOL_VERSION}") if close
    end

    private def violation(reason : String) : Nil
      @host.report(ChordError.new(ErrorCode::Invalid, "link to #{name || "peer"}: #{reason}", reason: "protocol"))
      @link.close("protocol error: #{reason}")
    end

    private def receive(frame : Frame) : Nil
      return if @mismatched
      @last_seen = Time.instant
      unless Wire.frame?(frame)
        violation("malformed frame")
        return
      end
      if frame.t == "ack"
        on_ack(frame.int("n"))
        return
      end
      @received += 1
      begin
        dispatch(frame)
      rescue error
        @host.report(error)
      end
      schedule_ack
    end

    private def dispatch(frame : Frame) : Nil
      case frame.t
      when "hello"         then on_hello(frame)
      when "ping"          then send(Frame.build("pong", n: frame.int("n")))
      when "pong", "bye"   then nil
      when "hold"          then on_hold(frame)
      when "release"       then drop_served(frame.int("id"), true)
      when "call"          then on_call(frame)
      when "cancel"        then @incoming[frame.int("id")]?.try &.abort(ChordError.new(ErrorCode::Aborted, "cancelled by caller"))
      when "sub", "unsub"  then on_want_state(frame.int("hold"), frame.t == "sub")
      when "resync"        then on_resync(frame.int("hold"), frame.string("m"))
      when "shape", "gone" then on_hold_reply(frame)
      when "result"        then on_result(frame)
      when "state"         then on_state(frame)
      when "root_end"      then @host.foreign_root_ended(frame.string("rootId"), self)
      when "vote"          then violation("vote from a non-participant")
      when "invalidate", "prepare", "commit", "abort", "retire"
        on_control(frame)
      end
    end

    private def on_control(frame : Frame) : Nil
      unless @role.upstream?
        violation("#{frame.t} from a child")
        return
      end
      case frame.t
      when "invalidate" then spawn { invalidate(frame["pattern"]) }
      when "retire"     then @host.allow_retire(frame.int("codeVersion").to_i32)
      else                   @host.on_reload_frame(self, frame)
      end
    end

    private def invalidate(pattern : JSON::Any) : Nil
      @host.invalidate_principal(pattern)
    rescue error
      @host.report(error)
    end

    private def on_hello(frame : Frame) : Nil
      protocol = frame["protocol"]?.try(&.as_i) || 1
      unless protocol == PROTOCOL_VERSION
        protocol_mismatch(protocol)
        return
      end
      if @peer_acks.nil?
        @peer_acks = frame["acks"]? == JSON::Any.new(true)
        unless @peer_acks
          @unacked.clear
          @unacked_bytes = 0_i64
        end
      end
      kind = frame.string("kind")
      if @role.upstream?
        unless kind == "host"
          violation("parent is not a host")
          return
        end
        @parent_name ||= frame.string("name")
        return
      end
      announced = frame.string("name")
      if kind != @peer.kind.label || (@peer.name && announced != @peer.name)
        violation("hello #{kind} #{announced} does not match the accepted #{@peer.kind.label} #{@peer.name}")
        return
      end
      @host.peer_hello(self, frame.int("codeVersion").to_i32) if @peer.kind.host?
    end

    private def principal_of(frame : Frame) : JSON::Any
      return @principal if @role.downstream?
      frame["principal"]? || @principal
    end

    private def origin_of(frame : Frame) : String?
      @role.downstream? ? @origin_id : frame.string?("origin")
    end

    private def on_hold(frame : Frame) : Nil
      id = frame.int("id")
      if @served.has_key?(id)
        violation("duplicate hold id #{id}")
        return
      end
      principal = principal_of(frame)
      origin = origin_of(frame)
      client = !origin.nil?
      if frame.string("at") != @host.name
        if @role.upstream?
          send(Frame.build("gone", id: id, error: Wire.to_error(ChordError.new(ErrorCode::Unavailable, "#{@host.name} does not relay"))))
          return
        end
        relay = RelayRef.new(self, frame, principal, origin)
        @served[id] = ServedRelay.new(relay)
        spawn { run_relay(relay) }
        return
      end
      ref = begin
        acquire_served(frame, principal, client)
      rescue error
        send(Frame.build("gone", id: id, error: Wire.to_error(client ? Connection.client_error(error) : error)))
        return
      end
      served = ServedLocal.new(id, ref, principal, origin, frame["state"]? != JSON::Any.new(false), frame["again"]? == JSON::Any.new(true))
      @served[id] = served
      ref.on_shape { unit(served) }
      ref.on_gone { |error| served_gone(served, error) }
      unit(served) if ref.status.live?
    end

    private def acquire_served(frame : Frame, principal : JSON::Any, client : Bool) : LocalRef
      token = Chord.contract_from_description(frame["token"])
      raise Chord.invalid("token", "#{token.name} is local; only remote types cross links") unless token.remote?
      placement = token.description.host.not_nil!
      unless placement.resolve(token.name, frame["input"]) == @host.name
        raise Chord.invalid("placement", "#{token.name} with this input does not live on #{@host.name}")
      end
      acquired = @host.acquire(token, frame["input"], principal, client ? RefOwner::Client : RefOwner::Connection)
      acquired.as?(LocalRef) || raise ChordError.new(ErrorCode::Unavailable, "not a local reference")
    end

    private def run_relay(relay : RelayRef) : Nil
      @host.relay(relay)
    rescue error
      relay.close(error, true, true)
    end

    private def served_gone(served : ServedLocal, error : Exception) : Nil
      return unless @served[served.id]?.same?(served)
      drop_served(served.id, false)
      send(Frame.build("gone", id: served.id, error: Wire.to_error(error)))
    end

    private def state_members(ref : LocalRef, shape : Shape) : Array(String)
      shape.members.select { |name| ref.describe(shape.variant, name).try(&.state?) }
    end

    private def unit(served : ServedLocal) : Nil
      return unless @served[served.id]?.same?(served)
      shape = served.ref.shape
      return unless shape
      members = served.wants_state? ? state_members(served.ref, shape).to_set : ::Set(String).new
      served.feeds.to_a.each do |(name, feed)|
        next if members.includes?(name)
        feed.unsubscribe.call
        served.feeds.delete(name)
        drop_state(served.id, name)
      end
      urgent = served.feeds.empty? && !(served.again? && !served.unit_sent?)
      if urgent
        send_unit(served)
      else
        queue_unit(served.id, unit_sender(served))
      end
    end

    private def unit_sender(served : ServedLocal) : Proc(Nil)
      -> { send_unit(served); nil }
    end

    private def send_unit(served : ServedLocal) : Nil
      @pending.delete(Connection.unit_key(served.id))
      return unless @served[served.id]?.same?(served)
      shape = served.ref.shape
      return unless shape
      served.unit_sent = true
      members = served.wants_state? ? state_members(served.ref, shape) : [] of String
      listed = members.reject { |name| served.feeds.has_key?(name) }
      snaps = [] of Frame
      attached = [] of Tuple(String, Feed)
      listed.each do |name|
        frame, feed = attach(served, name, "snap")
        snaps << frame
        attached << {name, feed}
      end
      fields = {
        "t"        => JSON::Any.new("shape"),
        "id"       => JSON::Any.new(served.id),
        "members"  => JSON::Any.new(shape.members.map { |member| JSON::Any.new(member) }),
        "contract" => JSON::Any.new(shape.contract),
        "state"    => JSON::Any.new(snaps.map(&.["m"])),
      }
      shape.variant.try { |variant| fields["variant"] = JSON::Any.new(variant) }
      send(Frame.new(fields))
      snaps.each { |frame| send(frame) }
      attached.each { |(name, feed)| replay(served, name, feed) }
    end

    private def attach(served : ServedLocal, name : String, kind : String) : Tuple(Frame, Feed)
      readable = served.ref.state(name)
      feed = Feed.new
      first = nil.as(StateEvent?)
      feed.unsubscribe = readable.events do |event|
        if first.nil?
          first = event
        elsif buffer = feed.buffer
          buffer << event
        else
          feed_event(served, name, feed, event)
        end
      end
      served.feeds[name] = feed
      {snapshot(served, name, kind, first.try(&.value)), feed}
    end

    private def replay(served : ServedLocal, name : String, feed : Feed) : Nil
      buffered = feed.buffer || [] of StateEvent
      feed.buffer = nil
      buffered.each { |event| feed_event(served, name, feed, event) }
    end

    private def snapshot(served : ServedLocal, name : String, kind : String, value : JSON::Any?) : Frame
      begin
        Connection.validate_snapshot(served.ref, name, value)
      rescue error
        return Frame.state(served.id, name, "error", error: Wire.to_error(error))
      end
      Frame.state(served.id, name, kind, value: value)
    end

    private def feed_event(served : ServedLocal, name : String, feed : Feed, event : StateEvent) : Nil
      return unless served.feeds[name]?.same?(feed)
      overflow = Overflow.new(resend: resender(served, name))
      if event.kind.ops?
        send_state(Frame.state(served.id, name, "ops", ops: feed.encoder.encode(event.ops)), overflow)
        return
      end
      feed.encoder = Delta::Encoder.new
      send_state(snapshot(served, name, "reset", event.value), overflow)
    end

    private def resender(served : ServedLocal, name : String) : Proc(Nil)
      -> { resend(served, name); nil }
    end

    private def resend(served : ServedLocal, name : String) : Nil
      feed = served.feeds[name]?
      return if feed.nil? || !@served[served.id]?.same?(served)
      feed.unsubscribe.call
      served.feeds.delete(name)
      frame, fresh = attach(served, name, "reset")
      send(frame)
      replay(served, name, fresh)
    end

    private def on_want_state(hold : Int64, wanted : Bool) : Nil
      case served = @served[hold]?
      when ServedRelay
        served.relay.want_state(wanted)
      when ServedLocal
        return if served.wants_state? == wanted
        served.wants_state = wanted
        if wanted
          unit(served)
          return
        end
        served.feeds.each_value(&.unsubscribe.call)
        served.feeds.clear
        drop_hold_state(hold)
      end
    end

    private def on_resync(hold : Int64, m : String) : Nil
      case served = @served[hold]?
      when ServedRelay
        served.relay.resync(m)
      when ServedLocal
        reset_later(hold, m, resender(served, m)) if served.feeds.has_key?(m)
      end
    end

    private def drop_served(id : Int64, release : Bool) : Nil
      served = @served.delete(id)
      case served
      when ServedRelay
        served.relay.close(ChordError.new(ErrorCode::Released, "relayed hold released"), release, false)
      when ServedLocal
        served.feeds.each_value(&.unsubscribe.call)
        served.feeds.clear
        drop_hold_state(id)
        served.ref.release if release
      end
    end

    private def on_call(frame : Frame) : Nil
      id = frame.int("id")
      if @incoming.has_key?(id)
        violation("duplicate call id #{id}")
        return
      end
      if (max = @max_calls) && @incoming.size >= max
        error = ChordError.new(ErrorCode::Unavailable,
          "Too many calls in progress on this connection (#{max}); wait for earlier ones to finish", reason: "too_many_calls")
        send(Frame.build("result", id: id, error: Wire.to_error(error)))
        return
      end
      served = @served[frame.int("hold")]?
      unless served
        send(Frame.build("result", id: id, error: Wire.to_error(ChordError.new(ErrorCode::Gone, "unknown hold"))))
        return
      end
      controller = AbortController.new
      @incoming[id] = controller
      root = @peer.kind.host? ? frame["root"]? : nil
      spawn { run_call(id, frame, served, root, controller) }
    end

    private def run_call(id : Int64, frame : Frame, served : Served, root : JSON::Any?, controller : AbortController) : Nil
      principal = case served
                  when ServedLocal then served.principal
                  when ServedRelay then served.relay.principal
                  else                  @principal
                  end
      result = if root
                 @host.join_root(root["rootId"].as_s, root["codeVersion"].as_i, principal: principal,
                   signal: controller.signal, from: self) { |ctx| perform(id, frame, served, ctx) }
               else
                 @host.root(principal: principal, signal: controller.signal) { |ctx| perform(id, frame, served, ctx) }
               end
      send(result)
    rescue error
      send(Frame.build("result", id: id, error: Wire.to_error(error)))
    ensure
      @incoming.delete(id)
    end

    private def perform(id : Int64, frame : Frame, served : Served, ctx : Ctx) : Frame
      case served
      when ServedLocal
        Frame.build("result", id: id, value: served.ref.object.call(served.ref, frame.string("member"), frame.payload, ctx))
      when ServedRelay
        relay_call(served.relay, frame, ctx).with("id", JSON::Any.new(id))
      else
        raise ChordError.new(ErrorCode::Gone, "unknown hold")
      end
    end

    private def relay_call(relay : RelayRef, frame : Frame, ctx : Ctx) : Frame
      signal = ctx.signal
      raise ChordError.new(ErrorCode::Aborted, "call cancelled", cause: signal.reason) if signal.aborted?
      ready = relay.ready_future
      if ready.wait([signal], nil).aborted?
        raise ChordError.new(ErrorCode::Aborted, "call cancelled", cause: signal.reason)
      end
      down = ready.wait
      raise ChordError.new(ErrorCode::Gone, "relayed hold closed") if relay.closed?
      pending = Future(Frame).new
      call = RelayCall.new(relay, frame.int("id"), down.next_id, pending)
      remove = signal.on_abort { |reason| call.cancel(ChordError.new(ErrorCode::Aborted, "call cancelled", cause: reason), true) }
      begin
        @host.root_sent(ctx.root_id, down)
        root = JSON::Any.new({"rootId" => JSON::Any.new(ctx.root_id), "codeVersion" => JSON::Any.new(ctx.code_version.to_i64)})
        forwarded = frame.with("id", JSON::Any.new(call.down_id)).with("hold", JSON::Any.new(relay.down_id)).with("root", root)
        down.send(forwarded)
        result = pending.wait
        if error = result["error"]?
          raise Wire.from_error(error)
        end
        result
      ensure
        remove.call
      end
    end

    private def on_hold_reply(frame : Frame) : Nil
      id = frame.int("id")
      if relay = @relayed_refs[id]?
        if frame.t == "gone"
          relay.close(Wire.from_error(frame["error"]), false, true)
        else
          relay.shape(frame)
        end
        return
      end
      binding = @remotes[id]?
      return unless binding
      if frame.t == "gone"
        @remotes.delete(id)
        binding.gone(Wire.from_error(frame["error"]))
        return
      end
      shape = Shape.new(frame.string?("variant"), frame["members"].as_a.map(&.as_s), frame.string("contract"))
      binding.shaped(shape, frame["state"].as_a.map(&.as_s))
    end

    private def on_result(frame : Frame) : Nil
      id = frame.int("id")
      if relayed = @relayed_calls[id]?
        relayed.finish(nil, frame)
        return
      end
      @calls.delete(id).try &.resolve(frame)
    end

    private def on_state(frame : Frame) : Nil
      hold = frame.int("hold")
      if relay = @relayed_refs[hold]?
        relay.state(frame)
        return
      end
      binding = @remotes[hold]?
      return unless binding
      value = begin
        frame.payload
      rescue error
        binding.state(frame.string("m"), Frame.state(hold, frame.string("m"), "error", error: Wire.to_error(error)), nil)
        return
      end
      binding.state(frame.string("m"), frame, value)
    end

    private def closed(reason : String) : Nil
      if (told = reason.match(/^protocol-version (\d+)$/)) && told[1].to_i != PROTOCOL_VERSION
        protocol_mismatch(told[1].to_i, false)
      end
      @pending.clear
      @pending_bytes = 0_i64
      error = ChordError.new(ErrorCode::Unavailable, "link to #{name || "peer"} closed: #{reason}")
      @served.keys.each { |id| drop_served(id, true) }
      @incoming.each_value(&.abort(error))
      @incoming.clear
      @calls.each_value(&.reject(error))
      @calls.clear
      waiters = @sync_waiters.dup
      @sync_waiters.clear
      waiters.each(&.reject(error))
      @relayed_refs.values.each(&.close(error, false, true))
      @relayed_refs.clear
      @relayed_calls.clear
      bindings = @remotes.values
      @remotes.clear
      bindings.each do |binding|
        if @role.upstream?
          binding.detached
        else
          binding.gone(error)
        end
      end
      @host.connection_closed(self)
    end

    protected def self.state_key(hold : Int64, m : String) : String
      "s#{hold}\u0000#{m}"
    end

    protected def self.unit_key(hold : Int64) : String
      "u#{hold}"
    end

    protected def self.client_error(error : Exception) : Exception
      return error unless error.is_a?(ChordError) && error.code.contract_mismatch?
      ChordError.new(ErrorCode::UpgradeRequired, error.message || "contract mismatch", cause: error)
    end

    protected def self.validate_snapshot(ref : LocalRef, member : String, value : JSON::Any?) : Nil
      return unless value
      installed = ref.object.current_installed
      return unless installed
      view = ref.current_view
      variant = view ? view.variant : installed.implementation.variant
      description = if view && !view.same?(installed.implementation)
                      ref.contract.description.variants[variant || LOCAL_VARIANT]?.try(&.[member]?)
                    else
                      installed.service.contract.description.variants[installed.implementation.variant || LOCAL_VARIANT]?.try(&.[member]?)
                    end
      schema = description.try { |found| found.state? ? found.schema : nil }
      Schema.assert_valid("state", "#{ref.address}.#{member}", schema, value) if schema
    end
  end
end
