# spec/readiness_spec.cr
require "./spec_helper"

private alias C = LLM::Chord
private alias T = TypeBox::Type

private EAGER = C.local("ready.eager", version: 1, input: T.object)
private LAZY  = C.local("ready.lazy", version: 1, input: T.object)

private def start(host : Host, operation : String, facet : Facet) : Nil
  operation == "install" ? host.install(facet) : host.load([facet])
end

describe "host: eager readiness" do
  %w[install load].each do |operation|
    it "#{operation} awaits resource activation and registration, leaving lazy objects lazy" do
      host = C.create_host(self: {kind: "host"}, on_error: ->(error : Exception) { raise error })
      entries = C.define_registry(String, "ready.entries")
      opened = Channel(Nil).new(1)
      lazy_runs = 0
      facet = C.define_facet("ready") do |api|
        api.serve(EAGER, lifetime: :host) do |_input, _principal, scope|
          scope.resource("r", version: 1) { opened.receive }
          scope.register(entries, {"eager" => "live"})
          Implementation.new
        end
        api.serve(LAZY) do
          lazy_runs += 1
          Implementation.new
        end
      end
      loading = Future(Nil).run { start(host, operation, facet) }
      tick
      loading.settled?.should be_false
      host.registry(entries).get("eager").should be_nil
      opened.send(nil)
      loading.wait
      host.registry(entries).get("eager").should eq "live"
      lazy_runs.should eq 0
    ensure
      host.try &.close
    end

    %w[factory dependency resource].each do |failure|
      it "#{operation} rejects eager #{failure} failure with the activation error" do
        errors = [] of Exception
        host = quiet_host(errors)
        cause = C.forbidden("#{failure} failed")
        facet = C.define_facet("bad") do |api|
          api.serve(LAZY) { raise cause }
          api.serve(EAGER, lifetime: :host) do |_input, _principal, scope|
            raise cause if failure == "factory"
            scope.get(LAZY) if failure == "dependency"
            if failure == "resource"
              scope.resource("r", version: 1) do
                raise cause if failure == "resource"
              end
            end
            Implementation.new
          end
        end
        expect_raises(ChordError) { start(host, operation, facet) }.should be(cause)
        expect_raises(ChordError) { host.ready }.should be(cause)
        errors.size.should eq 1
        errors[0].should be(cause)
      ensure
        host.try &.close
      end
    end
  end

  it "load installs every facet before awaiting eager consumers" do
    host = C.create_host(self: {kind: "host"}, on_error: ->(error : Exception) { raise error })
    consumer = C.define_facet("consumer") do |api|
      api.serve(EAGER, lifetime: :host) do |_input, _principal, scope|
        scope.get(LAZY)
        Implementation.new
      end
    end
    provider = C.define_facet("provider") { |api| api.serve(LAZY) { Implementation.new } }
    host.load([consumer, provider])
    host.hold(EAGER).status.should eq RefStatus::Live
  ensure
    host.try &.close
  end

  it "missing eager dependencies reject load instead of only reaching on_error" do
    host = quiet_host
    missing = C.define_facet("missing") do |api|
      api.serve(EAGER, lifetime: :host) do |_input, _principal, scope|
        scope.get(LAZY)
        Implementation.new
      end
    end
    error = expect_raises(ChordError) { host.load([missing]) }
    error.code.should eq ErrorCode::Unavailable
    error.reason.should eq "unknown_type"
  ensure
    host.try &.close
  end

  it "ready includes direct host serves" do
    host = quiet_host
    first = C.local("ready.first", version: 1, input: T.object)
    created = 0
    host.serve(first, lifetime: :host) do
      created += 1
      Implementation.new
    end
    host.ready
    created.should eq 1
    host.serve(EAGER, lifetime: :host) { raise C.forbidden("later") }
    expect_raises(ChordError, /later/) { host.ready }
  ensure
    host.try &.close
  end
end
