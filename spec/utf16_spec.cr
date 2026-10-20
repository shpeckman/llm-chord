# spec/utf16_spec.cr
require "./spec_helper"

describe LLM::Chord::Delta::Utf16 do
  it "counts ASCII as one unit per char" do
    LLM::Chord::Delta::Utf16.size("abc").should eq 3
  end

  it "counts astral characters as two units" do
    LLM::Chord::Delta::Utf16.size("😀").should eq 2
    LLM::Chord::Delta::Utf16.size("a😀b").should eq 4
  end

  it "slices by code units" do
    LLM::Chord::Delta::Utf16.slice("😀x", 2).should eq "x"
    LLM::Chord::Delta::Utf16.slice("abc", 1).should eq "bc"
    LLM::Chord::Delta::Utf16.slice("abc", 5).should eq ""
  end

  it "maps units back to a code-point boundary" do
    LLM::Chord::Delta::Utf16.chars_for_units("😀x", 2).should eq 1
  end
end
