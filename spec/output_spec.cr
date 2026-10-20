# spec/output_spec.cr
require "./spec_helper"

private def head(max_lines : Int, max_bytes : Int = 1000) : Output::Limits
  Output::Limits.head(max_lines, max_bytes)
end

private def tail(max_lines : Int, max_bytes : Int = 1000) : Output::Limits
  Output::Limits.tail(max_lines, max_bytes)
end

private def bound(text : String, limits : Output::Limits) : Tuple(String, Int64, Int64)
  excerpt = Output.bound(text, limits)
  {excerpt.text, excerpt.dropped_bytes, excerpt.dropped_lines}
end

private def byte_tail(content : String, max_bytes : Int32) : String
  bytes = content.to_slice
  return content if bytes.size <= max_bytes
  start = bytes.size - max_bytes
  while start < bytes.size && (bytes[start] & 0xc0) == 0x80
    start += 1
  end
  String.new(bytes[start..])
end

private class Mulberry32
  @state : UInt32

  def initialize(seed : Int)
    @state = seed.to_u32!
  end

  def next : Float64
    @state = @state &+ 0x6d2b79f5_u32
    t = @state
    t = (t ^ (t >> 15)) &* (t | 1_u32)
    t ^= t &+ ((t ^ (t >> 7)) &* (t | 61_u32))
    (t ^ (t >> 14)).to_f64 / 4294967296.0
  end

  def below(count : Int) : Int32
    (self.next * count).floor.to_i32
  end
end

ALPHABET = ["a", "b", "z", " ", "\n", "\n", "\n", "\r\n", "\t", "é", "€", "😀", "�", "\u0001", "\e"]

private def random_chunk(random : Mulberry32) : String
  String.build { |io| random.below(12).times { io << ALPHABET[random.below(ALPHABET.size)] } }
end

private def exceeds_window?(text : String, limits : Output::Limits) : Bool
  skip = Output::Skip.of(text)
  skip.bytes > limits.max_bytes || skip.newlines > limits.max_lines
end

private def char_boundaries(text : String) : Array(Int32)
  result = [0]
  offset = 0
  text.each_char do |char|
    offset += char.bytesize
    result << offset
  end
  result
end

private def check_skip_seed(seed : Int32) : Nil
  random = Mulberry32.new(seed)
  limits = Output::Limits.tail(1 + random.below(5), 1 + random.below(40))
  full = Output::Buffer.new(limits)
  skipping = Output::Buffer.new(limits)
  pending = ""
  flush = -> do
    unless pending.empty?
      bytes = pending.to_slice
      cuts = char_boundaries(pending).select { |cut| cut > 0 && exceeds_window?(String.new(bytes[cut..]), limits) }
      if !cuts.empty? && random.next < 0.7
        cut = cuts[random.below(cuts.size)]
        skipping.push(String.new(bytes[cut..]), Output::Skip.of(String.new(bytes[0, cut])))
      else
        skipping.push(pending)
      end
      pending = ""
      skipping.snapshot if random.next < 0.5
      skipping.snapshot.should eq full.snapshot
    end
  end
  random.below(40).times do
    chunk = random_chunk(random)
    full.push(chunk)
    full.snapshot if random.next < 0.3
    pending += chunk
    flush.call if random.next < 0.3
  end
  flush.call
  full.end
  skipping.end
  skipping.snapshot.should eq full.snapshot
end

private class FakeClock < Output::Clock
  class Armed
    property? disarmed = false
    getter delay_ms : Float64
    getter due : Float64
    getter callback : Proc(Nil)

    def initialize(@delay_ms : Float64, @due : Float64, @callback : Proc(Nil)); end
  end

  property now : Float64
  getter timers = [] of Armed

  def initialize(@now : Float64 = 0.0); end

  def after(delay_ms : Float64, &callback : ->) : Proc(Nil)
    disarmer(arm(delay_ms, callback))
  end

  def advance(milliseconds : Number) : Nil
    target = @now + milliseconds
    loop do
      timer = @timers.reject(&.disarmed?).select { |armed| armed.due <= target }.min_by?(&.due)
      break unless timer
      @now = timer.due
      timer.disarmed = true
      timer.callback.call
      settle
    end
    @now = target
    settle
  end

  def settle : Nil
    10.times { Fiber.yield }
  end

  private def arm(delay_ms : Float64, callback : Proc(Nil)) : Armed
    armed = Armed.new(delay_ms, @now + delay_ms, callback)
    @timers << armed
    armed
  end

  private def disarmer(armed : Armed) : Proc(Nil)
    -> { armed.disarmed = true; nil }
  end
end

describe "LLM::Chord::Output.bound" do
  it "removes control characters but keeps tabs, newlines, and other text" do
    Output.sanitize("a\u0000b\tc\nd\re\u0007f￹g￻h😀").should eq "ab\tc\ndefgh😀"
    text = "clean\ttext\n"
    Output.sanitize(text).should be text
  end

  it "keeps output within the limits unchanged" do
    bound("a\nb\n", head(2)).should eq({"a\nb\n", 0, 0})
    bound("a\nb", tail(2)).should eq({"a\nb", 0, 0})
    bound("", tail(2)).should eq({"", 0, 0})
  end

  it "keeps nothing with a zero limit" do
    bound("ab\ncd\n", head(10, 0)).should eq({"", 6, 2})
    bound("ab\ncd\n", tail(0)).should eq({"", 6, 2})
  end

  it "keeps exact slices of whole lines, trailing newline included" do
    bound("a\nb\nc\n", head(2)).should eq({"a\nb\n", 2, 1})
    bound("a\nb\nc\n", tail(2)).should eq({"b\nc\n", 2, 1})
    bound("a\nb\nc", tail(2)).should eq({"b\nc", 2, 1})
    bound("a\nb\nc\n\n", tail(3)).should eq({"b\nc\n\n", 2, 1})
  end

  it "cuts at the byte limit on whole lines when possible" do
    bound("aa\nbb\ncc\n", head(10, 7)).should eq({"aa\nbb\n", 3, 1})
    bound("aa\nbb\ncc\n", tail(10, 7)).should eq({"bb\ncc\n", 3, 1})
  end

  it "cuts a single line longer than the byte limit on a character boundary" do
    bound("ééé\n", head(10, 5)).should eq({"éé", 3, 0})
    bound("x\néééé", tail(10, 5)).should eq({"éé", 6, 1})
  end

  it "keeps a U+FEFF at the start of a kept slice" do
    bound("x﻿a", tail(10, 4)).should eq({"﻿a", 1, 0})
  end

  it "reports kept bytes" do
    Output.bound("aa\nbb\n", head(1)).bytes.should eq 3
  end

  it "cuts tails exactly like a character-boundary byte slice" do
    alphabet = ["a", "\u007f", "\u0080", "é", "߿", "ࠀ", "中", "퟿", "🙂", "", "￿"]
    check = ->(input : String, limits : Array(Int32)) do
      limits.each do |max_bytes|
        kept = Output.bound(input, tail(10, max_bytes)).text
        kept.should eq byte_tail(input, max_bytes)
        kept.bytesize.should be <= max_bytes
      end
    end
    sampled = ->(input : String) do
      total = input.bytesize
      [0, 1, 2, 3, 4, 5, 8, total // 2, total - 4, total - 1, total, total + 1].select(&.>=(0)).uniq!.sort!
    end
    inputs = [""]
    3.times do
      inputs = inputs.flat_map { |prefix| [prefix] + alphabet.map { |char| prefix + char } }.uniq!
    end
    inputs.each { |input| check.call(input, sampled.call(input)) }
    random = Mulberry32.new(0x12345678)
    1_000.times do
      input = String.build { |io| random.below(80).times { io << alphabet[random.below(alphabet.size)] } }
      check.call(input, sampled.call(input))
    end
  end

  it "finds the last character boundary at or before an index" do
    bytes = "aé".to_slice
    Output.character_end(bytes, 2).should eq 1
    Output.character_end(bytes, 3).should eq 3
    Output.utf8_byte_length("aé😀").should eq 7
  end
end

describe LLM::Chord::Output::Buffer do
  it "keeps exact totals across chunks and decodes UTF-8 split across byte chunks" do
    buffer = Output::Buffer.new(tail(2))
    bytes = "😀\n".to_slice
    buffer.push("a\nb\n")
    buffer.push(bytes[0, 2])
    buffer.push(bytes[2..])
    buffer.snapshot.should eq Output::Bounded.new("b\n😀\n", 2, 1)
  end

  it "sanitizes the retained text but counts the raw stream" do
    buffer = Output::Buffer.new(tail(1))
    buffer.push("a\u0007\n")
    buffer.snapshot.should eq Output::Bounded.new("a\n", 0, 0)
    buffer.push("b\e\n")
    buffer.snapshot.should eq Output::Bounded.new("b\n", 3, 1)
  end

  it "drops a byte-order mark only at the start of the output" do
    buffer = Output::Buffer.new(tail(10))
    buffer.push(Bytes[0xef])
    buffer.push(Bytes[0xbb, 0xbf, 0x61])
    buffer.push("b")
    buffer.push(Bytes[0xef, 0xbb, 0xbf, 0x63])
    buffer.end
    buffer.snapshot.text.should eq "ab﻿c"
  end

  it "flushes an incomplete character before a string chunk and at the end" do
    buffer = Output::Buffer.new(tail(10))
    euro = "€".to_slice
    buffer.push(euro[0, 1])
    buffer.push("x")
    buffer.push(euro[0, 2])
    buffer.end
    buffer.snapshot.text.should eq "�x�"
  end

  it "replaces invalid byte sequences like a WHATWG decoder" do
    buffer = Output::Buffer.new(tail(10))
    buffer.push(Bytes[0x61, 0xff, 0xc0, 0x80, 0xed, 0xa0, 0x80, 0x62])
    buffer.end
    buffer.snapshot.text.should eq "a������b"
  end

  it "reports whether a chunk was accepted" do
    buffer = Output::Buffer.new(tail(10))
    buffer.push("").should be_false
    buffer.push(Bytes[0xe2]).should be_false
    buffer.push("x").should be_true
  end

  it "matches bounding the whole stream when several chunks arrive between snapshots" do
    [head(3, 40), tail(3, 40), head(50, 25), tail(50, 25)].each do |limits|
      buffer = Output::Buffer.new(limits)
      stream = ""
      300.times do |index|
        chunk = index % 7 == 0 ? "#{"é" * (index % 30)}\n" : "line #{index}\n"
        stream += chunk
        buffer.push(chunk)
        next unless index % 5 == 4
        expected = Output.bound(stream, limits)
        buffer.snapshot.should eq Output::Bounded.new(expected.text, expected.dropped_bytes, expected.dropped_lines)
      end
    end
  end

  it "stops storing head output once the window is full" do
    buffer = Output::Buffer.new(head(2))
    1000.times { |index| buffer.push("line #{index}\n") }
    buffer.stored_bytes.should be < 20
    buffer.snapshot.should eq Output::Bounded.new("line 0\nline 1\n", 8876, 998)
  end

  it "stores only the tail window after each snapshot" do
    buffer = Output::Buffer.new(tail(3, 100))
    stream = ""
    2000.times do |index|
      chunk = "line #{index}\n\n"
      stream += chunk
      buffer.push(chunk)
      snapshot = buffer.snapshot
      buffer.stored_bytes.should be <= 100
      snapshot.text.should eq Output.bound(stream, tail(3, 100)).text
    end
  end

  it "keeps the same tail whenever progress snapshots happen" do
    (1..3000).each do |seed|
      random = Mulberry32.new(seed)
      limits = Output::Limits.tail(1 + random.below(5), 1 + random.below(40))
      plain = Output::Buffer.new(limits)
      sampled = Output::Buffer.new(limits)
      random.below(30).times do
        chunk = random_chunk(random)
        plain.push(chunk)
        sampled.push(chunk)
        sampled.snapshot if random.next < 0.4
      end
      sampled.snapshot.should eq plain.snapshot
    end
  end

  it "matches the full stream for every legal skip pattern" do
    (1..3000).each { |seed| check_skip_seed(seed) }
  end

  it "counts skipped bytes, lines and the final newline exactly" do
    limits = Output::Limits.tail(2, 1000)
    full = Output::Buffer.new(limits)
    skipping = Output::Buffer.new(limits)
    omitted = "one\ntwo\nthr"
    kept = "ee\nfour\nfive\nsix"
    full.push(omitted + kept)
    skipping.push(kept, Output::Skip.of(omitted))
    skipping.snapshot.should eq full.snapshot
    skipping.snapshot.should eq Output::Bounded.new("five\nsix", 19, 4)
  end

  it "refuses skips for head retention" do
    buffer = Output::Buffer.new(Output::Limits.head(2, 10))
    expect_raises(ArgumentError, /tail retention/) { buffer.push("x\ny\nz\n", Output::Skip.new(3, 1, true)) }
  end
end

describe LLM::Chord::Output::Progress do
  it "commits the first change at once, then waits at least the minimum and the written size" do
    clock = FakeClock.new
    commits = [] of Float64
    size = 50_i64 * 1024
    progress = Output::Progress.new(-> { commits << clock.now; size }, ->(_error : Exception) { }, 100, clock)
    progress.mark
    clock.settle
    commits.should eq [0.0]
    size = 10_i64
    progress.mark
    progress.mark
    clock.advance(499)
    commits.should eq [0.0]
    clock.advance(1)
    commits.should eq [0.0, 500.0]
    progress.mark
    clock.advance(99)
    commits.should eq [0.0, 500.0]
    clock.advance(1)
    commits.should eq [0.0, 500.0, 600.0]
  end

  it "waits the configured minimum interval between small commits" do
    clock = FakeClock.new
    commits = [] of Float64
    progress = Output::Progress.new(-> { commits << clock.now; 10_i64 }, ->(_error : Exception) { }, 500, clock)
    progress.mark
    clock.settle
    progress.mark
    clock.advance(499)
    commits.should eq [0.0]
    clock.advance(1)
    commits.should eq [0.0, 500.0]
  end

  it "paces on the clock it is given" do
    clock = FakeClock.new(1_000.0)
    commits = [] of Float64
    progress = Output::Progress.new(-> { commits << clock.now; 10_i64 }, ->(_error : Exception) { }, 100, clock)
    progress.mark_and_wait.wait
    commits.should eq [1_000.0]
    clock.settle
    clock.now = 1_040.0
    second = progress.mark_and_wait
    clock.timers.map(&.delay_ms).should eq [60.0]
    clock.now = 1_080.0
    clock.timers[0].callback.call
    commits.should eq [1_000.0]
    clock.timers.map(&.delay_ms).should eq [60.0, 20.0]
    clock.now = 1_100.0
    clock.timers[1].callback.call
    second.wait
    commits.should eq [1_000.0, 1_100.0]
    clock.settle
    progress.mark
    clock.timers.map(&.delay_ms).should eq [60.0, 20.0, 100.0]
    progress.stop
    clock.timers[2].disarmed?.should be_true
  end

  it "rejects the waiters of a failed commit and reports its error" do
    errors = [] of Exception
    failure = IO::Error.new("commit failed")
    progress = Output::Progress.new(-> : Int64 { raise failure }, ->(error : Exception) { errors << error; nil }, 100)
    raised = expect_raises(IO::Error) { progress.mark_and_wait.wait }
    raised.should be failure
    errors.should eq [failure]
  end

  it "stops: waits for the commit in flight and hands back waiters no commit covered yet" do
    gate = Channel(Nil).new
    progress = Output::Progress.new(-> { gate.receive; 0_i64 }, ->(_error : Exception) { }, 100, FakeClock.new)
    first = progress.mark_and_wait
    second = progress.mark_and_wait
    Fiber.yield
    spawn { gate.send(nil) }
    pending = progress.stop
    first.wait
    first.settled?.should be_true
    pending.size.should eq 1
    pending[0].should be second
    pending[0].resolve
    second.wait
  end

  it "paces on the system clock by default" do
    commits = [] of Time::Instant
    progress = Output::Progress.new(-> { commits << Time.instant; 0_i64 }, ->(_error : Exception) { }, 30)
    progress.mark_and_wait.wait
    progress.mark_and_wait.wait
    commits.size.should eq 2
    (commits[1] - commits[0]).total_milliseconds.should be >= 25
    progress.stop.should be_empty
  end
end
