# src/llm/chord/delta/diff.cr
module LLM::Chord::Delta
  def self.diff_revisions(before : JSON::Any, after : JSON::Any) : Array(Op)
    Diff.new.run(before, after)
  end

  class Diff
    DEFAULT_OVERLAP_SCAN    = 65_536
    MAX_DELTA_OPERATIONS    = 4_096
    MAX_LCS_CELLS           = 65_536
    MAX_IDENTITY_CANDIDATES = 200_000

    @ops = [] of Op
    @overflowed = false

    def run(before : JSON::Any, after : JSON::Any) : Array(Op)
      diff_value(before, after, [] of Seg)
      return [Op::Replace.new(after)] of Op if @overflowed
      ops = @ops
      return ops if ops.empty? || ops.first.is_a?(Op::Replace)
      delta_cost = 2
      ops.each { |op| delta_cost += op_cost(op) + 1 }
      return ops if delta_cost < 65_536
      snapshot_cost = json_cost(after) + 6
      delta_cost >= snapshot_cost ? [Op::Replace.new(after)] of Op : ops
    end

    private def emit(op : Op) : Nil
      return if @overflowed
      if @ops.size >= MAX_DELTA_OPERATIONS
        @overflowed = true
        return
      end
      @ops << op
    end

    private def emit_set(path : Path, value : JSON::Any) : Nil
      if path.empty?
        emit(Op::Replace.new(value))
      else
        emit(Op::Set.new(path, value))
      end
    end

    protected def diff_value(before : JSON::Any, after : JSON::Any, path : Path) : Nil
      return if @overflowed
      return if before == after
      rb = before.raw
      ra = after.raw
      if rb.is_a?(String) && ra.is_a?(String) && !path.empty?
        emit_string(rb, ra, path)
      elsif rb.is_a?(Array) && ra.is_a?(Array)
        diff_array(rb, ra, path)
      elsif rb.is_a?(Hash) && ra.is_a?(Hash)
        diff_object(rb, ra, path)
      else
        emit_set(path, after)
      end
    end

    private def emit_string(before : String, after : String, path : Path) : Nil
      return if before == after
      if after.size > before.size && after.starts_with?(before)
        emit(Op::Append.new(path, after[before.size, after.size - before.size]))
        return
      end
      shared = Delta.overlap(before, after, DEFAULT_OVERLAP_SCAN)
      if shared == 0
        emit(Op::Set.new(path, JSON::Any.new(after)))
        return
      end
      shared_chars = Utf16.chars_for_units(after, shared)
      emit(Op::Truncate.new(path, Utf16.size(before) - shared))
      if after.size > shared_chars
        emit(Op::Append.new(path, after[shared_chars, after.size - shared_chars]))
      end
    end

    private def diff_object(before : Hash(String, JSON::Any), after : Hash(String, JSON::Any), path : Path) : Nil
      if (before.keys + after.keys).any? { |key| RESERVED_SEGMENTS.includes?(key) }
        emit_set(path, JSON::Any.new(after))
        return
      end
      after.each do |key, value|
        return if @overflowed
        if before.has_key?(key)
          diff_value(before[key], value, path + [key])
        else
          emit_set(path + [key], value)
        end
      end
      before.each_key do |key|
        return if @overflowed
        emit(Op::Delete.new(path + [key])) unless after.has_key?(key)
      end
    end

    private def diff_array(before : Array(JSON::Any), after : Array(JSON::Any), path : Path) : Nil
      return if before == after
      if before.size == after.size && before.size > 1 &&
         before[0] != after[0] && before[-1] != after[-1]
        if order = permutation(before, after)
          emit(Op::Move.new(path, order))
          return
        end
      end
      diff_array_region(before, after, path, 0, before.size, 0, after.size, 0)
    end

    private def diff_array_region(
      before : Array(JSON::Any), after : Array(JSON::Any), path : Path,
      before_start : Int32, before_end : Int32, after_start : Int32, after_end : Int32, output_start : Int32,
    ) : Nil
      return if @overflowed
      while before_start < before_end && after_start < after_end && before[before_start] == after[after_start]
        before_start += 1
        after_start += 1
        output_start += 1
      end
      while before_start < before_end && after_start < after_end && before[before_end - 1] == after[after_end - 1]
        before_end -= 1
        after_end -= 1
      end
      before_count = before_end - before_start
      after_count = after_end - after_start
      return if before_count == 0 && after_count == 0
      if before_count == 0 || after_count == 0
        emit(Op::Splice.new(path, output_start, before_count, after[after_start...after_end]))
        return
      end
      if before_count == after_count
        positional = [] of {Int32, Int32}
        before_count.times do |offset|
          if before[before_start + offset] == after[after_start + offset]
            positional << {before_start + offset, after_start + offset}
          end
        end
        if !positional.empty?
          process_array_matches(before, after, path, before_start, before_end, after_start, after_end, output_start, positional)
          return
        end
      end
      if matches = lcs_matches(before[before_start...before_end], after[after_start...after_end])
        unless matches.empty?
          absolute = matches.map { |(before_index, after_index)| {before_start + before_index, after_start + after_index} }
          process_array_matches(before, after, path, before_start, before_end, after_start, after_end, output_start, absolute)
          return
        end
      end
      if before_count == 1 && after_count == 1
        diff_value(before[before_start], after[after_start], path + [output_start])
        return
      end
      emit(Op::Splice.new(path, output_start, before_count, after[after_start...after_end]))
    end

    private def process_array_matches(
      before : Array(JSON::Any), after : Array(JSON::Any), path : Path,
      before_start : Int32, before_end : Int32, after_start : Int32, after_end : Int32, output_start : Int32,
      matches : Array({Int32, Int32}),
    ) : Nil
      before_at = before_start
      after_at = after_start
      output_at = output_start
      matches.each do |(before_match, after_match)|
        return if @overflowed
        diff_array_region(before, after, path, before_at, before_match, after_at, after_match, output_at)
        output_at += after_match - after_at
        diff_value(before[before_match], after[after_match], path + [output_at]) unless before[before_match] == after[after_match]
        output_at += 1
        before_at = before_match + 1
        after_at = after_match + 1
      end
      diff_array_region(before, after, path, before_at, before_end, after_at, after_end, output_at) unless @overflowed
    end

    private def subsequence_matches(
      before : Array(JSON::Any), after : Array(JSON::Any),
      before_start : Int32, before_end : Int32, after_start : Int32, after_end : Int32,
    ) : Array({Int32, Int32})?
      before_count = before_end - before_start
      after_count = after_end - after_start
      return nil if before_count == after_count
      matches = [] of {Int32, Int32}
      if after_count < before_count
        before_index = before_start
        (after_start...after_end).each do |after_index|
          before_index += 1 while before_index < before_end && before[before_index] != after[after_index]
          return nil if before_index == before_end
          matches << {before_index, after_index}
          before_index += 1
        end
        return matches
      end
      after_index = after_start
      (before_start...before_end).each do |before_index|
        after_index += 1 while after_index < after_end && before[before_index] != after[after_index]
        return nil if after_index == after_end
        matches << {before_index, after_index}
        after_index += 1
      end
      matches
    end

    private def greedy_anchors(
      positions : Hash(JSON::Any, Array(Int32)),
      after : Array(JSON::Any), after_start : Int32, after_end : Int32,
    ) : Array({Int32, Int32})
      matches = [] of {Int32, Int32}
      previous = -1
      (after_start...after_end).each do |after_index|
        candidates = positions[after[after_index]]?
        next unless candidates
        at = lower_bound(candidates, previous + 1)
        next if at >= candidates.size
        before_index = candidates[at]
        matches << {before_index, after_index}
        previous = before_index
      end
      matches
    end

    private def identity_anchors(
      before : Array(JSON::Any), after : Array(JSON::Any),
      before_start : Int32, before_end : Int32, after_start : Int32, after_end : Int32,
    ) : Array({Int32, Int32})
      positions = {} of JSON::Any => Array(Int32)
      (before_start...before_end).each do |index|
        value = before[index]
        if positions.has_key?(value)
          positions[value] << index
        else
          positions[value] = [index]
        end
      end
      candidate_count = 0
      (after_start...after_end).each do |index|
        if indices = positions[after[index]]?
          candidate_count += indices.size
          return greedy_anchors(positions, after, after_start, after_end) if candidate_count > MAX_IDENTITY_CANDIDATES
        end
      end
      return [] of {Int32, Int32} if candidate_count == 0

      candidates = [] of Tuple(Int32, Int32, Int32)
      tails = [] of Int32
      tail_values = [] of Int32
      (after_start...after_end).each do |after_index|
        before_positions = positions[after[after_index]]?
        next unless before_positions
        (before_positions.size - 1).downto(0) do |idx|
          before_index = before_positions[idx]
          at = lower_bound(tail_values, before_index)
          candidate_index = candidates.size
          candidates << {before_index, after_index, at == 0 ? -1 : tails[at - 1]}
          if at == tails.size
            tails << candidate_index
            tail_values << before_index
          else
            tails[at] = candidate_index
            tail_values[at] = before_index
          end
        end
      end
      matches = [] of {Int32, Int32}
      candidate_index = tails.empty? ? -1 : tails[-1]
      while candidate_index >= 0
        candidate = candidates[candidate_index]
        matches << {candidate[0], candidate[1]}
        candidate_index = candidate[2]
      end
      matches.reverse!
    end

    private def lower_bound(values : Array(Int32), value : Int32) : Int32
      low = 0
      high = values.size
      while low < high
        middle = (low + high) // 2
        if values[middle] < value
          low = middle + 1
        else
          high = middle
        end
      end
      low
    end

    private def lcs_matches(before : Array(JSON::Any), after : Array(JSON::Any)) : Array({Int32, Int32})?
      return [] of {Int32, Int32} if before.empty? || after.empty?
      return if before.size.to_i64 * after.size.to_i64 > MAX_LCS_CELLS
      width = after.size + 1
      heights = before.size + 1
      lengths = Slice(Int32).new(heights * width, 0)
      (before.size - 1).downto(0) do |left|
        (after.size - 1).downto(0) do |right|
          at = left * width + right
          lengths[at] = if before[left] == after[right]
                          lengths[(left + 1) * width + right + 1] + 1
                        else
                          Math.max(lengths[(left + 1) * width + right], lengths[left * width + right + 1])
                        end
        end
      end
      matches = [] of {Int32, Int32}
      left = 0
      right = 0
      while left < before.size && right < after.size
        if before[left] == after[right] && lengths[left * width + right] == lengths[(left + 1) * width + right + 1] + 1
          matches << {left, right}
          left += 1
          right += 1
        elsif lengths[(left + 1) * width + right] >= lengths[left * width + right + 1]
          left += 1
        else
          right += 1
        end
      end
      matches
    end

    private def permutation(before : Array(JSON::Any), after : Array(JSON::Any)) : Array(Int32)?
      return unless before.size == after.size
      positions = {} of JSON::Any => Array(Int32)
      before.each_with_index do |value, index|
        (positions[value] ||= [] of Int32) << index
      end
      used = {} of JSON::Any => Int32
      result = Array(Int32).new(after.size)
      after.each do |value|
        indices = positions[value]?
        return unless indices
        used_count = used[value]? || 0
        return if used_count >= indices.size
        result << indices[used_count]
        used[value] = used_count + 1
      end
      result
    end

    private def json_cost(value : JSON::Any) : Int32
      case raw = value.raw
      when Nil
        4
      when String
        raw.size + 2
      when Int64
        raw.to_s.size
      when Float64
        raw.to_s.size
      when Bool
        raw ? 4 : 5
      when Array
        cost = 2
        raw.each_with_index { |child, index| cost += json_cost(child) + (index == 0 ? 0 : 1) }
        cost
      when Hash
        cost = 2
        index = 0
        raw.each do |key, child|
          cost += key.size + 3 + json_cost(child) + (index == 0 ? 0 : 1)
          index += 1
        end
        cost
      else
        0
      end
    end

    private def path_cost(path : Path) : Int32
      cost = 2
      path.each_with_index do |seg, index|
        cost += (seg.is_a?(String) ? seg.size + 2 : seg.to_s.size) + (index == 0 ? 0 : 1)
      end
      cost
    end

    private def op_cost(op : Op) : Int32
      case op
      when Op::Replace
        6 + json_cost(op.value)
      when Op::Set
        7 + path_cost(op.path) + json_cost(op.value)
      when Op::Delete
        6 + path_cost(op.path)
      when Op::Append
        7 + path_cost(op.path) + op.text.size + 2
      when Op::Truncate
        7 + path_cost(op.path) + op.count.to_s.size
      when Op::Splice
        10 + path_cost(op.path) + op.index.to_s.size + op.remove.to_s.size + json_cost(JSON::Any.new(op.items))
      when Op::Move
        7 + path_cost(op.path) + json_cost(JSON::Any.new(op.permutation.map { |value| JSON::Any.new(value.to_i64) }))
      else
        0
      end
    end
  end
end
