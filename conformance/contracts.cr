# conformance/contracts.cr
require "../src/llm-chord"

module Conformance
  T = TypeBox::Type
  C = LLM::Chord

  COUNTER = C.remote("t.conformance-counter", version: 1, input: T.object, host: C.host_named("w1"), variants: {
    main: C.variant(state: {count: T.object({n: T.number})}, methods: {add: C.method(T.number, T.number), who: C.method(nil, T.unknown)}),
  })

  BOARD = C.remote("t.conformance-board", version: 1, input: T.object, host: C.host_named("server"), variants: {
    main: C.variant(state: {notes: T.array(T.string)}, methods: {add: C.method(T.string), who: C.method(nil, T.unknown)}),
  })
end
