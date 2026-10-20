# src/llm/chord/delta/apply.cr
module LLM::Chord::Delta
  def self.apply(target : JSON::Any, ops : Array(Op)) : JSON::Any
    apply_ops(target, ops)
  end

  def self.apply_immutable(target : JSON::Any, ops : Array(Op)) : JSON::Any
    apply_immutable_batches(target, [ops])
  end

  def self.apply_immutable_batches(target : JSON::Any, batches : Array(Array(Op))) : JSON::Any
    root = Json.deep_copy(target)
    batches.each do |ops|
      root = apply_ops(root, ops)
    end
    root
  end

  private def self.apply_ops(root : JSON::Any, ops : Array(Op)) : JSON::Any
    current = root
    ops.each do |op|
      case op
      when Op::Replace
        current = Json.deep_copy(op.value)
      when Op::Splice
        array = resolve_container(current, op.path)
        raw = array.raw
        raise PathError.new(op.path) unless raw.is_a?(Array)
        raw[op.index, op.remove] = op.items.map { |item| Json.deep_copy(item) }
      when Op::Move
        array = resolve_container(current, op.path)
        raw = array.raw
        raise PathError.new(op.path) unless raw.is_a?(Array) && raw.size == op.permutation.size
        previous = raw.dup
        op.permutation.each_with_index { |from, index| raw[index] = previous[from] }
      when Op::Set
        apply_leaf(current, op)
      when Op::Delete
        apply_leaf(current, op)
      when Op::Append
        apply_leaf(current, op)
      when Op::Truncate
        apply_leaf(current, op)
      end
    end
    current
  end

  private def self.apply_leaf(root : JSON::Any, op : Op) : Nil
    path = op_path(op)
    raise ArgumentError.new("op path is empty") if path.empty?
    assert_safe_path(path)
    parent = resolve_container(root, path[0...-1])
    key = path[-1]
    case op
    when Op::Set
      write!(parent, key, Json.deep_copy(op.value))
    when Op::Delete
      delete!(parent, key)
    when Op::Append
      current = read!(parent, key)
      write!(parent, key, JSON::Any.new(current.as_s + op.text))
    when Op::Truncate
      current = read!(parent, key).as_s
      write!(parent, key, JSON::Any.new(current[op.count, current.size - op.count]))
    end
  end

  private def self.op_path(op : Op) : Path
    case op
    when Op::Set      then op.path
    when Op::Delete   then op.path
    when Op::Append   then op.path
    when Op::Truncate then op.path
    when Op::Splice   then op.path
    when Op::Move     then op.path
    else                   raise ArgumentError.new("replace op has no path")
    end
  end

  private def self.resolve_container(root : JSON::Any, path : Path) : JSON::Any
    assert_safe_path(path)
    node = root
    path.each do |seg|
      raw = node.raw
      if seg.is_a?(String)
        raise PathError.new(path) unless raw.is_a?(Hash)
        child = raw[seg]?
        raise PathError.new(path) if child.nil?
        node = child
      else
        raise PathError.new(path) unless raw.is_a?(Array)
        raise PathError.new(path) unless seg >= 0 && seg < raw.size
        node = raw[seg]
      end
    end
    raise PathError.new(path) unless Json.container?(node)
    node
  end

  private def self.write!(parent : JSON::Any, key : Seg, value : JSON::Any) : Nil
    raw = parent.raw
    if key.is_a?(String)
      raise PathError.new([] of Seg) unless raw.is_a?(Hash)
      raw[key] = value
    else
      raise PathError.new([] of Seg) unless raw.is_a?(Array)
      raise UnsafePathError.new(key) if key > raw.size
      if key == raw.size
        raw << value
      else
        raw[key] = value
      end
    end
  end

  private def self.delete!(parent : JSON::Any, key : Seg) : Nil
    raw = parent.raw
    if key.is_a?(String)
      raise PathError.new([] of Seg) unless raw.is_a?(Hash)
      raw.delete(key)
    else
      raise PathError.new([] of Seg) unless raw.is_a?(Array)
      raise PathError.new([] of Seg) if key >= raw.size
      raw.delete_at(key)
    end
  end

  private def self.read!(parent : JSON::Any, key : Seg) : JSON::Any
    raw = parent.raw
    if key.is_a?(String)
      raise PathError.new([] of Seg) unless raw.is_a?(Hash)
      value = raw[key]?
      raise PathError.new([] of Seg) if value.nil?
      value
    else
      raise PathError.new([] of Seg) unless raw.is_a?(Array)
      raise PathError.new([] of Seg) unless key >= 0 && key < raw.size
      raw[key]
    end
  end
end
