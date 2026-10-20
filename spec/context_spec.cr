# spec/context_spec.cr
require "./spec_helper"

describe LLM::Chord::Context do
  it "starts from empty background and todo contexts" do
    key = ContextKey(String).new("name")
    Context::BACKGROUND.value(key).should be_nil
    Context::TODO.value(key).should be_nil
    Context::BACKGROUND.to_s.should eq "[Context BACKGROUND_CONTEXT]"
    Context::TODO.to_s.should eq "[Context TODO_CONTEXT]"
  end

  it "derives contexts carrying typed values without changing the parent" do
    name = ContextKey(String).new("name")
    count = ContextKey(Int32).new("count")
    derived = Context::BACKGROUND.with_value(name, "alice").with_value(count, 3)
    derived.value(name).should eq "alice"
    derived.value(count).should eq 3
    Context::BACKGROUND.value(name).should be_nil
    derived.to_s.should eq "[Context BACKGROUND_CONTEXT].WithValue(name).WithValue(count)"
  end

  it "shadows a key with the nearest value" do
    key = ContextKey(String).new
    outer = Context::BACKGROUND.with_value(key, "outer")
    inner = outer.with_value(key, "inner")
    inner.value(key).should eq "inner"
    outer.value(key).should eq "outer"
    inner.to_s.should contain "WithValue(anonymous)"
  end

  it "distinguishes keys by identity, not description" do
    first = ContextKey(String).new("same")
    second = ContextKey(String).new("same")
    context = Context::BACKGROUND.with_value(first, "value")
    context.value(first).should eq "value"
    context.value(second).should be_nil
  end

  it "carries reference values" do
    key = ContextKey(Array(Int32)).new("list")
    list = [1, 2]
    context = Context::BACKGROUND.with_value(key, list)
    context.value(key).should be list
  end
end
