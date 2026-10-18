# spec/spec_helper.cr
require "spec"
require "../src/llm-chord"

def path(*segs : String | Int32) : LLM::Chord::Delta::Path
  segs.to_a
end
