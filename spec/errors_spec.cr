# spec/errors_spec.cr
require "./spec_helper"

describe LLM::Chord::ChordError do
  it "formats code and reason into the message" do
    ChordError.new(ErrorCode::NotReady, "loading").message.should eq "not_ready: loading"
    ChordError.new(ErrorCode::Invalid, "bad args", reason: "args").message.should eq "invalid/args: bad args"
    ChordError.new(ErrorCode::Invalid, "x", reason: "").message.should eq "invalid: x"
  end

  it "labels every code like upstream" do
    ErrorCode.values.map(&.label).should eq %w[
      aborted contract_mismatch forbidden gone invalid not_in_variant not_ready released
      superseded unavailable upgrade_conflict upgrade_required
    ]
  end

  it "marks only superseded and upgrade conflicts retryable" do
    ErrorCode.values.select(&.retryable?).should eq [ErrorCode::Superseded, ErrorCode::UpgradeConflict]
    ChordError.new(ErrorCode::Superseded, "old").retryable?.should be_true
    ChordError.new(ErrorCode::Gone, "x").retryable?.should be_false
  end

  it "carries details and cause" do
    cause = IO::Error.new("socket")
    error = ChordError.new(ErrorCode::Unavailable, "down", details: j(%({"host":"a"})), cause: cause)
    error.details.should eq j(%({"host":"a"}))
    error.cause.should be cause
  end

  it "classifies chord errors" do
    LLM::Chord.chord_error?(LLM::Chord.forbidden).should be_true
    LLM::Chord.chord_error?(LLM::Chord.forbidden, ErrorCode::Forbidden).should be_true
    LLM::Chord.chord_error?(LLM::Chord.forbidden, ErrorCode::Gone).should be_false
    LLM::Chord.chord_error?(Exception.new("plain")).should be_false
  end

  it "builds forbidden and invalid errors" do
    LLM::Chord.forbidden.message.should eq "forbidden: forbidden"
    LLM::Chord.forbidden("guests may not").message.should eq "forbidden: guests may not"
    invalid = LLM::Chord.invalid("cycle", "dependency cycle", j(%(["a","b"])))
    invalid.code.invalid?.should be_true
    invalid.reason.should eq "cycle"
    invalid.details.should eq j(%(["a","b"]))
  end

  it "keeps chord error codes and wraps anything else as unavailable" do
    original = LLM::Chord.invalid("args", "bad")
    LLM::Chord.as_chord_error(original, "call").should be original
    cause = ArgumentError.new("boom")
    wrapped = LLM::Chord.as_chord_error(cause, "loading counter")
    wrapped.code.unavailable?.should be_true
    wrapped.message.should eq "unavailable: loading counter: boom"
    wrapped.cause.should be cause
  end

  it "runs every step and raises one error or an aggregate" do
    ran = [] of Int32
    LLM::Chord.run_all([-> { ran << 1; nil }, -> { ran << 2; nil }], "cleanup failed")
    ran.should eq [1, 2]
    single = ArgumentError.new("one")
    raised = expect_raises(ArgumentError) do
      LLM::Chord.run_all([-> { raise single }, -> { ran << 3; nil }], "cleanup failed")
    end
    raised.should be single
    ran.should eq [1, 2, 3]
    aggregate = expect_raises(AggregateError, "cleanup failed") do
      LLM::Chord.run_all([-> { raise "a" }, -> { raise "b" }], "cleanup failed")
    end
    aggregate.errors.map(&.message).should eq ["a", "b"]
  end
end
