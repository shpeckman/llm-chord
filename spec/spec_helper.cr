# spec/spec_helper.cr
require "spec"
require "../src/llm-chord"

include LLM::Chord
include LLM::Chord::Delta

def j(text : String) : JSON::Any
  JSON.parse(text)
end

def list(*items : JSON::Any) : JSON::Any
  JSON::Any.new(items.to_a)
end

def list(items : Array(JSON::Any)) : JSON::Any
  JSON::Any.new(items)
end

def doc(**fields) : JSON::Any
  hash = {} of String => JSON::Any
  fields.each { |key, value| hash[key.to_s] = value.is_a?(JSON::Any) ? value : Json.to_any(value) }
  JSON::Any.new(hash)
end

def path(*segs : String | Int32) : Delta::Path
  result = Delta::Path.new
  segs.each { |seg| result << seg }
  result
end

def tuples(ops : Array(Op)) : JSON::Any
  JSON::Any.new(ops.map(&.to_tuple))
end

def expect_diff(before : JSON::Any, after : JSON::Any, expected : String) : Array(Op)
  ops = Delta.diff_revisions(before, after)
  tuples(ops).should eq j(expected)
  Json.equal?(Delta.apply_immutable(before, ops), after).should be_true
  ops
end

def same?(left : JSON::Any, right : JSON::Any) : Bool
  Json.identical?(left, right)
end

def ops(text : String) : Array(Op)
  j(text).as_a.map { |tuple| Op.from_tuple(tuple) }
end
