# spec/fixtures/worker.cr
require "../../src/llm-chord"

ECHO = LLM::Chord.remote("t.echo", version: 1, input: TypeBox::Type.object, host: LLM::Chord.host_named("w1"), variants: {
  main: LLM::Chord.variant(methods: {
    echo: LLM::Chord.method(TypeBox::Type.string, TypeBox::Type.string),
    pid:  LLM::Chord.method(nil, TypeBox::Type.number),
  }),
})

mode = ENV["FIXTURE_MODE"]? || "normal"
control = LLM::Chord.child_control
if mode == "fatal"
  control.fatal(Exception.new("fixture refuses to start"))
  sleep 200.milliseconds
  exit 1
end
begin
  control.lock
rescue
  sleep 200.milliseconds
  exit 1
end
host = LLM::Chord::Host.new(self: {kind: "host"}, name: ENV["HOST_NAME"]? || "worker",
  on_error: ->(_error : Exception) { },
  upstream: LLM::Chord::Upstream.new(control.link, JSON.parse(%({"kind":"server"})), LLM::Chord::LinkOptions.new))
greeting = control.init.wait.try(&.["greeting"]?.try(&.as_s)) || ""
host.serve(ECHO) do
  LLM::Chord::Implementation.new("main")
    .method("echo") { |text| "#{greeting} #{text.not_nil!.as_s} from #{Process.pid}" }
    .method("pid") { Process.pid }
end
if file = ENV["GRANDCHILD_FILE"]?
  grandchild = Process.new("sleep", ["1000"])
  File.write(file, grandchild.pid.to_s)
end
done = Channel(Nil).new
control.on_shutdown do
  next if mode == "ignore-shutdown"
  host.close
  exit 0
end
control.ready
done.receive
