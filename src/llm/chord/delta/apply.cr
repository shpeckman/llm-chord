# src/llm/chord/delta/apply.cr
module LLM::Chord::Delta
  def self.apply(target : JSON::Any, ops : Enumerable(Op)) : JSON::Any
    root = target
    ops.each { |op| root = apply_op(root, op) }
    root
  end

  def self.apply_immutable(target : JSON::Any, ops : Enumerable(Op)) : JSON::Any
    apply_immutable_batches(target, {ops})
  end

  def self.apply_immutable_batches(target : JSON::Any, batches : Enumerable) : JSON::Any
    root = target
    scope = CopyScope.new
    batches.each do |ops|
      ops.each do |op|
        case op
        when Op::Replace
          root = op.value
        when Op::Splice
          if appended = scope.append_copy(root, op)
            root = appended
          else
            root = apply_op(scope.copy_containers(root, op.path), op)
          end
        when Op::Move
          root = apply_op(scope.copy_containers(root, op.path), op)
        when Op::Targeted
          root = apply_op(scope.copy_containers(root, op.path[0...-1]), op)
        end
      end
    end
    root
  end

  protected def self.apply_op(root : JSON::Any, op : Op) : JSON::Any
    case op
    when Op::Replace
      return op.value
    when Op::Splice
      array = resolve(root, op.path).raw
      raise PathError.new(op.path) unless array.is_a?(Array)
      start = Math.min(op.index, array.size)
      array[start, Math.min(op.remove, array.size - start)] = op.items
    when Op::Move
      array = resolve(root, op.path).raw
      raise PathError.new(op.path) unless array.is_a?(Array) && array.size == op.permutation.size
      previous = array.dup
      op.permutation.each_with_index { |from, index| array[index] = previous[from] }
    when Op::Targeted
      apply_leaf(root, op)
    end
    root
  end

  private def self.apply_leaf(root : JSON::Any, op : Op::Targeted) : Nil
    path = op.path
    parent = resolve(root, path[0...-1]).raw
    key = path[-1]
    case parent
    when Array
      index = key.as?(Int32) || raise UnsafePathError.new(key)
      raise UnsafePathError.new(index) if index > parent.size
      case op
      when Op::Set
        index == parent.size ? parent << op.value : (parent[index] = op.value)
      when Op::Delete
        raise PathError.new(path) if index >= parent.size
        parent.delete_at(index)
      when Op::Append
        current = index < parent.size ? parent[index].as_s? : nil
        raise PathError.new(path) unless current
        parent[index] = JSON::Any.new(current + op.text)
      when Op::Truncate
        current = index < parent.size ? parent[index].as_s? : nil
        raise PathError.new(path) unless current
        parent[index] = JSON::Any.new(Utf16.slice(current, op.count))
      end
    when Hash
      name = key.to_s
      case op
      when Op::Set
        parent[name] = op.value
      when Op::Delete
        parent.delete(name)
      when Op::Append
        current = parent[name]?.try(&.as_s?)
        raise PathError.new(path) unless current
        parent[name] = JSON::Any.new(current + op.text)
      when Op::Truncate
        current = parent[name]?.try(&.as_s?)
        raise PathError.new(path) unless current
        parent[name] = JSON::Any.new(Utf16.slice(current, op.count))
      end
    end
  end

  protected def self.resolve(root : JSON::Any, path : Path) : JSON::Any
    node = root
    path.each do |seg|
      case raw = node.raw
      when Array
        index = seg.as?(Int32) || raise UnsafePathError.new(seg)
        raise PathError.new(path) unless 0 <= index < raw.size
        node = raw[index]
      when Hash
        node = raw[seg.to_s]? || raise PathError.new(path)
      else
        raise PathError.new(path)
      end
    end
    raise PathError.new(path) unless Json.container?(node)
    node
  end

  private class CopyScope
    @owned = ::Set(UInt64).new
    @pins = [] of JSON::Any

    def owned?(value : JSON::Any) : Bool
      @owned.includes?(identity(value))
    end

    def own_copy(value : JSON::Any) : JSON::Any
      raw = value.raw
      copy = raw.is_a?(Array) ? JSON::Any.new(raw.dup) : JSON::Any.new(raw.as(Hash).dup)
      own(copy)
      copy
    end

    def own(value : JSON::Any) : Nil
      @owned.add(identity(value))
      @pins << value
    end

    def append_copy(root : JSON::Any, op : Op::Splice) : JSON::Any?
      return unless op.remove == 0
      target = root
      op.path.each do |seg|
        raw = target.raw
        if seg.is_a?(String) && raw.is_a?(Hash) && (child = raw[seg]?)
          target = child
        elsif seg.is_a?(Int32) && raw.is_a?(Array) && seg < raw.size
          target = raw[seg]
        else
          return
        end
      end
      array = target.raw
      return unless array.is_a?(Array)
      return if owned?(target) || op.index != array.size
      appended = JSON::Any.new(array + op.items)
      own(appended)
      return appended if op.path.empty?
      parent_path = op.path[0...-1]
      copied_root = copy_containers(root, parent_path)
      case parent = Delta.resolve(copied_root, parent_path).raw
      when Hash
        parent[op.path[-1].to_s] = appended
      when Array
        parent[op.path[-1].as(Int32)] = appended
      end
      copied_root
    end

    def copy_containers(root : JSON::Any, path : Path) : JSON::Any
      raise PathError.new(path) unless Json.container?(root)
      copied_root = owned?(root) ? root : own_copy(root)
      destination = copied_root
      path.each do |seg|
        raw = destination.raw
        child = case raw
                when Array
                  index = seg.as?(Int32) || raise UnsafePathError.new(seg)
                  raise PathError.new(path) unless 0 <= index < raw.size
                  raw[index]
                when Hash
                  raw[seg.to_s]? || raise PathError.new(path)
                else
                  raise PathError.new(path)
                end
        raise PathError.new(path) unless Json.container?(child)
        if owned?(child)
          destination = child
          next
        end
        copied_child = own_copy(child)
        case raw
        when Array
          raw[seg.as(Int32)] = copied_child
        when Hash
          raw[seg.to_s] = copied_child
        end
        destination = copied_child
      end
      copied_root
    end

    private def identity(value : JSON::Any) : UInt64
      raw = value.raw
      raw.is_a?(Array) ? raw.object_id : raw.as(Hash).object_id
    end
  end
end
