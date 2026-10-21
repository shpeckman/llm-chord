# src/llm/chord/sqlite/sqlite3.cr
require "sqlite3"

module LLM::Chord::Sqlite
  DEFAULT_WAL_AUTOCHECKPOINT_PAGES = 1_000
  DEFAULT_BUSY_TIMEOUT_MS          = 5_000

  class SerialQueue
    @busy = false
    @waiters = Deque(Channel(Nil)).new

    def synchronize(&)
      acquire
      begin
        yield
      ensure
        release
      end
    end

    private def acquire : Nil
      if @busy
        turn = Channel(Nil).new(1)
        @waiters << turn
        turn.receive
      else
        @busy = true
      end
    end

    private def release : Nil
      if turn = @waiters.shift?
        turn.send(nil)
      else
        @busy = false
      end
    end
  end

  abstract class Sqlite3Executor < Executor
    def initialize(@connection : SQLite3::Connection); end

    def exec(sql : String) : Nil
      operation do
        handle = @connection.to_unsafe
        code = LibSQLite3.exec(handle, sql, nil, nil, nil)
        raise SQLite3::Exception.new(handle) unless code == LibSQLite3::Code::OKAY.value
      end
    end

    def run_values(sql : String, params : Array(Value)) : Nil
      operation { @connection.exec(sql, args: params) }
      nil
    end

    def get_values(sql : String, params : Array(Value)) : Row?
      operation { rows(sql, params, 1).first? }
    end

    def all_values(sql : String, params : Array(Value)) : Array(Row)
      operation { rows(sql, params, Int32::MAX) }
    end

    protected abstract def operation(&)

    private def rows(sql : String, params : Array(Value), limit : Int32) : Array(Row)
      result = [] of Row
      @connection.query(sql, args: params) do |set|
        names = set.column_names
        set.each do
          row = Row.new(initial_capacity: names.size)
          names.each { |name| row[name] = set.read.as(Value) }
          result << row
          break if result.size >= limit
        end
      end
      result
    end
  end

  class Sqlite3Transaction < Sqlite3Executor
    class Scope
      property? active = true
    end

    def initialize(connection : SQLite3::Connection, @scope : Scope)
      super(connection)
    end

    protected def operation(&)
      raise Error.new("SQLite transaction handle is no longer active") unless @scope.active?
      yield
    end
  end

  class Sqlite3Database < Database
    @access = SerialQueue.new
    @closed = false

    def initialize(@connection : SQLite3::Connection)
      @executor = Direct.new(@connection)
    end

    def exec(sql : String) : Nil
      @access.synchronize { open_executor.exec(sql) }
    end

    def run_values(sql : String, params : Array(Value)) : Nil
      @access.synchronize { open_executor.run_values(sql, params) }
    end

    def get_values(sql : String, params : Array(Value)) : Row?
      @access.synchronize { open_executor.get_values(sql, params) }
    end

    def all_values(sql : String, params : Array(Value)) : Array(Row)
      @access.synchronize { open_executor.all_values(sql, params) }
    end

    def transaction(&)
      @access.synchronize do
        executor = open_executor
        executor.exec("BEGIN IMMEDIATE")
        scope = Sqlite3Transaction::Scope.new
        begin
          result = yield Sqlite3Transaction.new(@connection, scope)
          scope.active = false
          executor.exec("COMMIT")
          result
        rescue error
          scope.active = false
          begin
            executor.exec("ROLLBACK")
          rescue exception
            raise AggregateError.new([error, exception], "SQLite transaction failed and rollback failed")
          end
          raise error
        end
      end
    end

    def close : Nil
      @access.synchronize do
        next if @closed
        @closed = true
        begin
          @executor.exec("PRAGMA wal_checkpoint(TRUNCATE)")
        ensure
          @connection.close
        end
      end
    end

    def closed? : Bool
      @closed
    end

    private def open_executor : Direct
      raise Error.new("SQLite database is closed") if @closed
      @executor
    end

    class Direct < Sqlite3Executor
      protected def operation(&)
        yield
      end
    end
  end

  def self.open_database(path : String, *, wal_autocheckpoint_pages : Int = DEFAULT_WAL_AUTOCHECKPOINT_PAGES,
                         busy_timeout_ms : Int = DEFAULT_BUSY_TIMEOUT_MS) : Sqlite3Database
    Dir.mkdir_p(File.dirname(path)) unless path == ":memory:"
    options = SQLite3::Connection::Options.new(filename: path, busy_timeout: busy_timeout_ms.to_s)
    database = Sqlite3Database.new(SQLite3::Connection.new(DB::Connection::Options.new, options))
    begin
      database.exec("PRAGMA journal_mode = WAL")
      database.exec("PRAGMA synchronous = NORMAL")
      database.exec("PRAGMA wal_autocheckpoint = #{wal_autocheckpoint_pages.to_i}")
      database
    rescue error
      database.close rescue nil
      raise error
    end
  end
end
