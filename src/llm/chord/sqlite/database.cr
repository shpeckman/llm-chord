# src/llm/chord/sqlite/database.cr
module LLM::Chord::Sqlite
  alias Value = (Int64 | Float64 | String | Bytes)?
  alias Row = Hash(String, Value)

  class Error < Exception
  end

  def self.value(value : Value) : Value
    value
  end

  def self.value(value : Int) : Value
    value.to_i64
  end

  def self.value(value : Float) : Value
    value.to_f64
  end

  def self.values(params : Tuple) : Array(Value)
    result = Array(Value).new(params.size)
    params.each { |param| result << value(param) }
    result
  end

  abstract class Executor
    abstract def exec(sql : String) : Nil
    abstract def run_values(sql : String, params : Array(Value)) : Nil
    abstract def get_values(sql : String, params : Array(Value)) : Row?
    abstract def all_values(sql : String, params : Array(Value)) : Array(Row)

    def run(sql : String, *params) : Nil
      run_values(sql, Sqlite.values(params))
    end

    def get(sql : String, *params) : Row?
      get_values(sql, Sqlite.values(params))
    end

    def all(sql : String, *params) : Array(Row)
      all_values(sql, Sqlite.values(params))
    end
  end

  abstract class Database < Executor
    abstract def transaction(& : Executor -> _)
    abstract def close : Nil
  end
end
