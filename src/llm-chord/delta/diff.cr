# src/llm-chord/delta/diff.cr
module LLM::Chord::Delta
  def self.diff_revisions(before : JSON::Any, after : JSON::Any) : Array(Op)
    Diff.new.run(before, after)
  end

  class Diff
    DEFAULT_OVERLAP_SCAN    =  65_536
    MAX_DELTA_OPERATIONS    =   4_096
    MAX_IDENTITY_CANDIDATES = 200_000
    MAX_SEMANTIC_CELLS      =  65_536
    MAX_DELTA_COST          =  65_536

    alias Identity = Tuple(UInt64, Bool | Int64 | Float64 | String?)
    alias Match = Tuple(Int32, Int32)

    @operations = [] of Op
    @overflowed = false

    def run(before : JSON::Any, after : JSON::Any) : Array(Op)
      diff_value(before, after, [] of Seg)
      return [Op::Replace.new(after)] of Op if @overflowed
      operations = @operations
      return operations if operations.empty? || operations.first.replace?
      delta_cost = 2_i64
      operations.each { |operation| delta_cost += operation_cost(operation) + 1 }
      return operations if delta_cost < MAX_DELTA_COST
      delta_cost >= json_cost(after) + 6 ? [Op::Replace.new(after)] of Op : operations
    end

    private def emit(operation : Op) : Nil
      return if @overflowed
      if @operations.size >= MAX_DELTA_OPERATIONS
        @overflowed = true
        return
      end
      @operations << operation
    end

    private def emit_set(path : Path, value : JSON::Any) : Nil
      path.empty? ? emit(Op::Replace.new(value)) : emit(Op::Set.new(path, value))
    end

    private def diff_value(before : JSON::Any, after : JSON::Any, path : Path) : Nil
      return if @overflowed || Json.identical?(before, after)
      a = before.raw
      b = after.raw
      if a.is_a?(String) && b.is_a?(String) && !path.empty?
        emit_string(a, b, path)
      elsif a.is_a?(Array) && b.is_a?(Array)
        diff_array(a, b, path)
      elsif a.is_a?(Hash) && b.is_a?(Hash)
        diff_object(a, b, path)
      else
        emit_set(path, after)
      end
    end

    private def emit_string(before : String, after : String, path : Path) : Nil
      return if before == after
      if after.size > before.size && after.starts_with?(before)
        emit(Op::Append.new(path, after[before.size..]))
        return
      end
      shared = Delta.overlap(before, after, DEFAULT_OVERLAP_SCAN)
      if shared == 0
        emit(Op::Set.new(path, JSON::Any.new(after)))
        return
      end
      shared_chars = Utf16.chars_for_units(after, shared)
      emit(Op::Truncate.new(path, Utf16.size(before) - shared))
      emit(Op::Append.new(path, after[shared_chars..])) if after.size > shared_chars
    end

    private def diff_object(before : Hash(String, JSON::Any), after : Hash(String, JSON::Any), path : Path) : Nil
      if before.each_key.any? { |key| RESERVED_SEGMENTS.includes?(key) } ||
         after.each_key.any? { |key| RESERVED_SEGMENTS.includes?(key) }
        emit_set(path, JSON::Any.new(after)) unless Json.equal?(JSON::Any.new(before), JSON::Any.new(after))
        return
      end
      after.each do |key, value|
        return if @overflowed
        if previous = before[key]?
          diff_value(previous, value, path + [key.as(Seg)])
        else
          emit_set(path + [key.as(Seg)], value)
        end
      end
      before.each_key do |key|
        return if @overflowed
        emit(Op::Delete.new(path + [key.as(Seg)])) unless after.has_key?(key)
      end
    end

    private def diff_array(before : Array(JSON::Any), after : Array(JSON::Any), path : Path) : Nil
      return if before.same?(after) || Json.equal?(JSON::Any.new(before), JSON::Any.new(after))
      if before.size == after.size && before.size > 1 &&
         !Json.equal?(before[0], after[0]) && !Json.equal?(before[-1], after[-1])
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
      while before_start < before_end && after_start < after_end && Json.equal?(before[before_start], after[after_start])
        before_start += 1
        after_start += 1
        output_start += 1
      end
      while before_start < before_end && after_start < after_end && Json.equal?(before[before_end - 1], after[after_end - 1])
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
        positional = [] of Match
        before_count.times do |offset|
          if Json.equal?(before[before_start + offset], after[after_start + offset])
            positional << {before_start + offset, after_start + offset}
          end
        end
        unless positional.empty?
          process_matches(before, after, path, before_start, before_end, after_start, after_end, output_start, positional)
          return
        end
      end

      if (subsequence = identity_subsequence(before, before_start, before_end, after, after_start, after_end)) && !subsequence.empty?
        process_matches(before, after, path, before_start, before_end, after_start, after_end, output_start, subsequence)
        return
      end

      identity = identity_anchors(before, before_start, before_end, after, after_start, after_end)
      unless identity.empty?
        process_matches(before, after, path, before_start, before_end, after_start, after_end, output_start, identity)
        return
      end

      if (semantic = semantic_matches(before[before_start...before_end], after[after_start...after_end])) && !semantic.empty?
        absolute = semantic.map { |(before_index, after_index)| {before_start + before_index, after_start + after_index} }
        process_matches(before, after, path, before_start, before_end, after_start, after_end, output_start, absolute)
        return
      end

      if before_count == 1 && after_count == 1
        diff_value(before[before_start], after[after_start], path + [output_start.as(Seg)])
        return
      end
      emit(Op::Splice.new(path, output_start, before_count, after[after_start...after_end]))
    end

    private def process_matches(
      before : Array(JSON::Any), after : Array(JSON::Any), path : Path,
      before_start : Int32, before_end : Int32, after_start : Int32, after_end : Int32, output_start : Int32,
      matches : Array(Match),
    ) : Nil
      before_at = before_start
      after_at = after_start
      output_at = output_start
      matches.each do |(before_match, after_match)|
        return if @overflowed
        diff_array_region(before, after, path, before_at, before_match, after_at, after_match, output_at)
        output_at += after_match - after_at
        unless Json.equal?(before[before_match], after[after_match])
          diff_value(before[before_match], after[after_match], path + [output_at.as(Seg)])
        end
        output_at += 1
        before_at = before_match + 1
        after_at = after_match + 1
      end
      diff_array_region(before, after, path, before_at, before_end, after_at, after_end, output_at) unless @overflowed
    end

    private def identity(value : JSON::Any) : Identity
      case raw = value.raw
      when Hash
        {raw.object_id, nil}
      when Array
        {raw.object_id, nil}
      else
        {0_u64, raw}
      end
    end

    private def identity_subsequence(
      before : Array(JSON::Any), before_start : Int32, before_end : Int32,
      after : Array(JSON::Any), after_start : Int32, after_end : Int32,
    ) : Array(Match)?
      before_count = before_end - before_start
      after_count = after_end - after_start
      matches = [] of Match
      if after_count < before_count
        before_index = before_start
        (after_start...after_end).each do |after_index|
          while before_index < before_end && !Json.identical?(before[before_index], after[after_index])
            before_index += 1
          end
          return if before_index == before_end
          matches << {before_index, after_index}
          before_index += 1
        end
        return matches
      end
      if before_count < after_count
        after_index = after_start
        (before_start...before_end).each do |before_index|
          while after_index < after_end && !Json.identical?(before[before_index], after[after_index])
            after_index += 1
          end
          return if after_index == after_end
          matches << {before_index, after_index}
          after_index += 1
        end
        return matches
      end
      nil
    end

    private def greedy_identity_anchors(
      positions : Hash(Identity, Array(Int32)),
      after : Array(JSON::Any), after_start : Int32, after_end : Int32,
    ) : Array(Match)
      matches = [] of Match
      previous = -1
      (after_start...after_end).each do |after_index|
        candidates = positions[identity(after[after_index])]?
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
      before : Array(JSON::Any), before_start : Int32, before_end : Int32,
      after : Array(JSON::Any), after_start : Int32, after_end : Int32,
    ) : Array(Match)
      positions = {} of Identity => Array(Int32)
      (before_start...before_end).each do |index|
        (positions[identity(before[index])] ||= [] of Int32) << index
      end
      candidate_count = 0
      (after_start...after_end).each do |index|
        candidate_count += positions[identity(after[index])]?.try(&.size) || 0
        return greedy_identity_anchors(positions, after, after_start, after_end) if candidate_count > MAX_IDENTITY_CANDIDATES
      end
      return [] of Match if candidate_count == 0

      candidates = [] of Tuple(Int32, Int32, Int32)
      tails = [] of Int32
      tail_values = [] of Int32
      (after_start...after_end).each do |after_index|
        before_positions = positions[identity(after[after_index])]?
        next unless before_positions
        (before_positions.size - 1).downto(0) do |position|
          before_index = before_positions[position]
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
      matches = [] of Match
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

    private def semantically_aligned?(left : JSON::Any, right : JSON::Any) : Bool
      return true if Json.equal?(left, right)
      a = left.raw
      b = right.raw
      if a.is_a?(Array) && b.is_a?(Array)
        return false unless a.size == b.size
        a.each_with_index.any? { |(value, index)| Json.container?(value) && Json.identical?(value, b[index]) }
      elsif a.is_a?(Hash) && b.is_a?(Hash)
        a.any? do |key, value|
          other = b[key]?
          !other.nil? && Json.container?(value) && Json.identical?(value, other)
        end
      else
        false
      end
    end

    private def semantic_matches(before : Array(JSON::Any), after : Array(JSON::Any)) : Array(Match)?
      return [] of Match if before.empty? || after.empty?
      return if before.size.to_i64 * after.size.to_i64 > MAX_SEMANTIC_CELLS
      width = after.size + 1
      lengths = Slice(UInt32).new((before.size + 1) * width, 0_u32)
      (before.size - 1).downto(0) do |left|
        (after.size - 1).downto(0) do |right|
          lengths[left * width + right] = if semantically_aligned?(before[left], after[right])
                                            lengths[(left + 1) * width + right + 1] + 1
                                          else
                                            Math.max(lengths[(left + 1) * width + right], lengths[left * width + right + 1])
                                          end
        end
      end
      matches = [] of Match
      left = 0
      right = 0
      while left < before.size && right < after.size
        if semantically_aligned?(before[left], after[right]) &&
           lengths[left * width + right] == lengths[(left + 1) * width + right + 1] + 1
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
      positions = {} of Identity => Array(Int32)
      before.each_with_index { |value, index| (positions[identity(value)] ||= [] of Int32) << index }
      used = {} of Identity => Int32
      result = Array(Int32).new(after.size)
      after.each do |value|
        key = identity(value)
        indices = positions[key]?
        return unless indices
        count = used[key]? || 0
        return if count >= indices.size
        result << indices[count]
        used[key] = count + 1
      end
      result
    end

    private def json_cost(value : JSON::Any) : Int64
      case raw = value.raw
      when Nil
        4_i64
      when String
        Utf16.size(raw).to_i64 + 2
      when Int64, Float64
        Json.number_text(raw).size.to_i64
      when Bool
        raw ? 4_i64 : 5_i64
      when Array
        cost = 2_i64
        raw.each_with_index { |child, index| cost += json_cost(child) + (index == 0 ? 0 : 1) }
        cost
      when Hash
        cost = 2_i64
        raw.each_with_index do |(key, child), index|
          cost += json_cost(child) + Utf16.size(key) + 3 + (index == 0 ? 0 : 1)
        end
        cost
      else
        0_i64
      end
    end

    private def path_cost(path : Path) : Int64
      cost = 2_i64
      path.each_with_index do |seg, index|
        cost += (seg.is_a?(String) ? Utf16.size(seg) + 2 : seg.to_s.size).to_i64 + (index == 0 ? 0 : 1)
      end
      cost
    end

    private def operation_cost(operation : Op) : Int64
      case operation
      when Op::Replace
        json_cost(operation.value) + 6
      when Op::Set
        path_cost(operation.path) + json_cost(operation.value) + 7
      when Op::Delete
        path_cost(operation.path) + 6
      when Op::Append
        path_cost(operation.path) + Utf16.size(operation.text) + 9
      when Op::Truncate
        path_cost(operation.path) + operation.count.to_s.size + 7
      when Op::Splice
        path_cost(operation.path) + operation.index.to_s.size + operation.remove.to_s.size +
          json_cost(JSON::Any.new(operation.items)) + 10
      when Op::Move
        path_cost(operation.path) + json_cost(JSON::Any.new(operation.permutation.map { |index| JSON::Any.new(index.to_i64) })) + 7
      else
        0_i64
      end
    end
  end
end
