# spec/spec_helper.cr
require "spec"
require "../src/llm-chord"

include LLM::Chord::Delta

def path(*segs : String | Int32) : LLM::Chord::Delta::Path
  segs.to_a
end

def diff_revisions(before : JSON::Any, after : JSON::Any) : Array(Op)
  LLM::Chord::Delta.diff_revisions(before, after)
end

def apply(target : JSON::Any, ops : Array(Op)) : JSON::Any
  LLM::Chord::Delta.apply(target, ops)
end

def apply_immutable(target : JSON::Any, ops : Array(Op)) : JSON::Any
  LLM::Chord::Delta.apply_immutable(target, ops)
end

def apply_immutable_batches(target : JSON::Any, batches : Array(Array(Op))) : JSON::Any
  LLM::Chord::Delta.apply_immutable_batches(target, batches)
end

def track(initial : JSON::Any) : LLM::Chord::Delta::Tracker
  LLM::Chord::Delta.track(initial)
end
