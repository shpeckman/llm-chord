# spec/diff_spec.cr
require "./spec_helper"

describe "LLM::Chord::Delta.diff_revisions" do
  it "emits sets and deletes" do
    expect_diff(j(%({"keep":1,"change":1,"remove":true})), j(%({"keep":1,"change":2,"add":3})),
      %([["s",["change"],2],["s",["add"],3],["d",["remove"]]]))
  end

  it "emits string append and front truncation" do
    expect_diff(j(%({"text":"hello"})), j(%({"text":"hello world"})), %([["a",["text"]," world"]]))
    expect_diff(j(%({"text":"hello world"})), j(%({"text":"world"})), %([["t",["text"],6]]))
    expect_diff(j(%({"text":"abcdefgh"})), j(%({"text":"defghxyz"})), %([["t",["text"],3],["a",["text"],"xyz"]]))
  end

  it "counts truncation in UTF-16 code units" do
    expect_diff(j(%({"text":"😀abc"})), j(%({"text":"abcd"})), %([["t",["text"],2],["a",["text"],"d"]]))
  end

  it "represents array insertion, removal, and shift with splices" do
    a = doc(id: "a")
    b = doc(id: "b")
    c = doc(id: "c")
    expect_diff(doc(values: list(a, b)), doc(values: list(a, c, b)), %([["p",["values"],1,0,[{"id":"c"}]]]))
    expect_diff(doc(values: list(a, b, c)), doc(values: list(b, c)), %([["p",["values"],0,1,[]]]))
  end

  it "collapses a same-length queue update to two splices" do
    a, b, c, d = doc(id: "a"), doc(id: "b"), doc(id: "c"), doc(id: "d")
    expect_diff(doc(values: list(a, b, c)), doc(values: list(b, c, d)),
      %([["p",["values"],0,1,[]],["p",["values"],2,0,[{"id":"d"}]]]))
  end

  it "emits a permutation for a pure reorder" do
    a, b, c = doc(id: "a"), doc(id: "b"), doc(id: "c")
    expect_diff(doc(values: list(a, b, c)), doc(values: list(c, a, b)), %([["m",["values"],[2,0,1]]]))
  end

  it "normalizes reordered distinct deeply-equal objects to a no-op" do
    first = j(%({"nested":{"value":1}}))
    second = j(%({"nested":{"value":1}}))
    same?(first, second).should be_false
    Delta.diff_revisions(doc(values: list(first, second)), doc(values: list(second, first))).should be_empty
  end

  it "emits nothing for deeply equal reconstructed values" do
    Delta.diff_revisions(j(%({"value":{"nested":[1,2]}})), j(%({"value":{"nested":[1,2]}}))).should be_empty
    Delta.diff_revisions(j(%({"values":[{"id":1},{"id":2}]})), j(%({"values":[{"id":1},{"id":2}]}))).should be_empty
    Delta.diff_revisions(j(%({"values":[true,true,true]})), j(%({"values":[true,true,true]}))).should be_empty
  end

  it "keeps a leaf edit inside a reconstructed array narrow" do
    expect_diff(
      j(%({"values":[{"id":1,"label":"one"},{"id":2,"label":"two"}]})),
      j(%({"values":[{"id":1,"label":"one"},{"id":2,"label":"changed"}]})),
      %([["s",["values",1,"label"],"changed"]]))
  end

  it "emits payload-free splices for scattered removals" do
    a, b, c, d, e = %w[a b c d e].map { |id| doc(id: id) }
    expect_diff(doc(values: list(a, b, c, d, e)), doc(values: list(a, c, e)),
      %([["p",["values"],1,1,[]],["p",["values"],2,1,[]]]))
  end

  it "encodes removals canonically" do
    expect_diff(j(%({"values":[1,2,3,4]})), j(%({"values":[2,3,4]})), %([["p",["values"],0,1,[]]]))
    expect_diff(j(%({"values":[1,2,3,4]})), j(%({"values":[1,2,3]})), %([["p",["values"],3,1,[]]]))
    expect_diff(j(%({"values":[1,2,3,4]})), j(%({"values":[1,3,4]})), %([["p",["values"],1,1,[]]]))
    expect_diff(j(%({"values":[1,2,3,4]})), j(%({"values":[]})), %([["p",["values"],0,4,[]]]))
    expect_diff(j(%({"values":[1,2,3,4]})), j(%({"values":[1,2,3,4]})), %([]))
  end

  it "does not field-diff unrelated shifted objects with common fields" do
    before = list([1, 2, 3].map { |value| doc(type: "row", value: value) })
    after = list([2, 3, 4].map { |value| doc(type: "row", value: value) })
    expect_diff(doc(values: before), doc(values: after),
      %([["p",["values"],0,1,[]],["p",["values"],2,0,[{"type":"row","value":4}]]]))
  end

  it "does not treat coincidental id or key fields as structural identity" do
    left = doc(value: "left")
    right = doc(value: "right")
    before = list(left, j(%({"id":1,"key":"a","value":"first"})), j(%({"id":2,"key":"b","value":"second"})), right)
    after = list(left, j(%({"id":2,"key":"b","value":"edited-second"})), j(%({"id":1,"key":"a","value":"edited-first"})), right)
    expect_diff(doc(values: before), doc(values: after),
      %([["p",["values"],1,2,[{"id":2,"key":"b","value":"edited-second"},{"id":1,"key":"a","value":"edited-first"}]]]))
  end

  it "combines removals, append, and a shared-subtree survivor edit" do
    rows = %w[a b c d].map { |id| doc(id: id, stable: j("{}"), detail: doc(text: id)) }
    changed = doc(id: "c", stable: rows[2]["stable"], detail: doc(text: "changed"))
    appended = doc(id: "e", stable: j("{}"), detail: doc(text: "e"))
    expect_diff(doc(values: list(rows)), doc(values: list(rows[0], changed, rows[3], appended)),
      %([["p",["values"],1,1,[]],["a",["values",1,"detail","text"],"hanged"],["p",["values"],3,0,[{"id":"e","stable":{},"detail":{"text":"e"}}]]]))
  end

  it "does not retain a large removed-neighbor payload" do
    payload = "x" * (256 * 1024)
    retained = %w[a b c d e].map { |id| doc(id: id, payload: payload) }
    before = doc(values: list(retained))
    after = doc(values: list(retained[0], retained[2], retained[4]))
    operations = expect_diff(before, after, %([["p",["values"],1,1,[]],["p",["values"],2,1,[]]]))
    tuples(operations).to_json.size.should be < 100
  end

  it "keeps push, pop, and middle removal narrow on long arrays" do
    [1_001, 10_000].each do |size|
      values = (0...size).map { |value| doc(value: value) }
      appended = doc(value: size)
      expect_diff(doc(values: list(values)), doc(values: list(values + [appended])),
        %([["p",["values"],#{size},0,[{"value":#{size}}]]]))
      expect_diff(doc(values: list(values)), doc(values: list(values[0...-1])), %([["p",["values"],#{size - 1},1,[]]]))
      middle = size // 2
      expect_diff(doc(values: list(values)), doc(values: list(values[0...middle] + values[(middle + 1)..])),
        %([["p",["values"],#{middle},1,[]]]))
    end
  end

  it "keeps forty-thousand-row sparse edits narrow" do
    values = (0...40_000).map { |value| doc(value: value, stable: doc(value: value)) }
    after = values.dup
    changed = [] of Int32
    100.step(to: after.size - 1, by: 400) do |index|
      after[index] = doc(value: -index, stable: values[index]["stable"])
      changed << index
    end
    operations = Delta.diff_revisions(doc(values: list(values)), doc(values: list(after)))
    tuples(operations).should eq j("[#{changed.join(',') { |index| %(["s",["values",#{index},"value"],#{-index}]) }}]")
    tuples(operations).to_json.size.should be < 7_500
    Json.equal?(Delta.apply_immutable(doc(values: list(values)), operations), doc(values: list(after))).should be_true
  end

  it "keeps a reconstructed large-array leaf edit narrow" do
    before = (0...1_000).map { |value| doc(value: value, label: "row-#{value}") }
    after = before.map { |row| Json.deep_copy(row) }
    after[700].as_h["label"] = JSON::Any.new("changed")
    expect_diff(doc(values: list(before)), doc(values: list(after)), %([["s",["values",700,"label"],"changed"]]))
  end

  it "splices an ambiguous equal-count moved-and-edited gap" do
    left = doc(value: "left")
    right = doc(value: "right")
    before = list(left, j(%({"id":1,"value":"a"})), j(%({"id":2,"value":"b"})), right)
    after = list(left, j(%({"id":2,"value":"edited"})), j(%({"id":1,"value":"also-edited"})), right)
    expect_diff(doc(values: before), doc(values: after),
      %([["p",["values"],1,2,[{"id":2,"value":"edited"},{"id":1,"value":"also-edited"}]]]))
  end

  it "keeps a large rotation payload-free" do
    values = (0...10_000).map { |value| doc(value: value) }
    rotated = values[1_000..] + values[0...1_000]
    operations = Delta.diff_revisions(doc(values: list(values)), doc(values: list(rotated)))
    operations.size.should eq 1
    operations[0].verb.should eq 'm'
    tuples(operations).to_json.size.should be < 60_000
    Json.equal?(Delta.apply_immutable(doc(values: list(values)), operations), doc(values: list(rotated))).should be_true
  end

  it "encodes five hundred unshifts without snapshotting retained rows" do
    retained = (0...10_000).map { |value| doc(value: value, payload: "x" * 100) }
    inserted = (0...500).map { |value| doc(value: -value - 1) }
    operations = Delta.diff_revisions(doc(values: list(retained)), doc(values: list(inserted + retained)))
    operations.size.should eq 1
    splice = operations[0].as(Op::Splice)
    {splice.index, splice.remove, splice.items.size}.should eq({0, 0, 500})
    tuples(operations).to_json.size.should be < 20_000
  end

  it "bounds wide-object operation emission with a root replacement" do
    before = {} of String => JSON::Any
    after = {} of String => JSON::Any
    20_000.times do |index|
      before["field#{index}"] = JSON::Any.new(0_i64)
      after["field#{index}"] = JSON::Any.new(1_i64)
    end
    operations = Delta.diff_revisions(JSON::Any.new(before), JSON::Any.new(after))
    operations.size.should eq 1
    operations[0].as(Op::Replace).value.should eq JSON::Any.new(after)
  end

  it "bounds a wide normalized array fallback with a root replacement" do
    before = doc(values: list((0...40_000).map { JSON::Any.new(0_i64) }))
    after = doc(values: list((0...40_000).map { JSON::Any.new(1_i64) }))
    operations = Delta.diff_revisions(before, after)
    operations.size.should eq 1
    operations[0].replace?.should be_true
    Json.equal?(Delta.apply_immutable(before, operations), after).should be_true
  end

  it "folds edits under reserved keys into a set of the nearest safe ancestor" do
    expect_diff(j(%({"node":{"__proto__":1}})), j(%({"node":{"__proto__":2}})), %([["s",["node"],{"__proto__":2}]]))
    expect_diff(j(%({"__proto__":1})), j(%({"__proto__":2})), %([["r",{"__proto__":2}]]))
  end

  it "replaces the root when its type changes" do
    expect_diff(j(%({"a":1})), j(%([1])), %([["r",[1]]]))
  end
end
