# spec/overlap_spec.cr
require "./spec_helper"

describe "LLM::Chord::Delta.overlap" do
  it "finds a shared suffix/prefix" do
    LLM::Chord::Delta.overlap("hello world", "world foo", 65_536).should eq 5
  end

  it "finds a full overlap" do
    LLM::Chord::Delta.overlap("abc", "abcd", 65_536).should eq 3
  end

  it "returns zero for disjoint strings" do
    LLM::Chord::Delta.overlap("abc", "xyz", 65_536).should eq 0
  end

  it "returns zero for an empty left string" do
    LLM::Chord::Delta.overlap("", "abc", 65_536).should eq 0
  end

  it "returns zero for an empty right string" do
    LLM::Chord::Delta.overlap("abc", "", 65_536).should eq 0
  end

  it "returns zero for a non-positive scan" do
    LLM::Chord::Delta.overlap("abc", "abc", 0).should eq 0
  end

  it "limits the search to the scan window" do
    a = "x" * 50_000 + "suffix"
    LLM::Chord::Delta.overlap(a, "suffix more", 1_000).should eq 6
  end

  it "honors an explicit probe length" do
    LLM::Chord::Delta.overlap("abcd", "bcdx", 65_536, probe: 2).should eq 3
  end

  it "returns a UTF-16 code unit count for astral characters" do
    LLM::Chord::Delta.overlap("a😀", "😀b", 65_536).should eq 2
  end
end
