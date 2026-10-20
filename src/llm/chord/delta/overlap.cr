# src/llm/chord/delta/overlap.cr
module LLM::Chord::Delta
  def self.overlap(a : String, b : String, scan : Int32, probe = 64, max_candidates = 8) : Int32
    return 0 if a.empty? || b.empty? || scan <= 0
    tail = a.size > scan ? a[a.size - scan, scan] : a
    [Math.min(probe, b.size), 1].each do |head_len|
      head = b[0, head_len]
      tried = 0
      k = tail.index(head)
      while k
        break if (tried += 1) > max_candidates
        n = tail.size - k
        return Utf16.size(b[0, n]) if n <= b.size && tail[k, n] == b[0, n]
        k = tail.index(head, k + 1)
      end
      break if head_len == 1
    end
    0
  end
end
