# spec/context_spec.cr
require "./spec_helper"
include LLM::Chord

describe LLM::Chord::Context do
  it "provides, requires and fetches entries" do
    context = LLM::Chord::Context.new
    value = JSON.parse(%({"a":1}))
    context.provide("cfg", value)
    context.require("cfg").should eq value
    context.fetch("cfg").should eq value
    context.fetch("missing").should be_nil
  end

  it "rejects duplicate provides" do
    context = LLM::Chord::Context.new
    context.provide("cfg", JSON.parse(%(1)))
    expect_raises(ArgumentError) { context.provide("cfg", JSON.parse(%(2))) }
  end

  it "rejects a missing requirement" do
    context = LLM::Chord::Context.new
    expect_raises(ArgumentError) { context.require("missing") }
  end
end
