# spec/sqlite_database_spec.cr
require "./spec_helper"
require "../src/llm-chord/sqlite"
require "file_utils"

alias Rows = Array(Sqlite::Row)

describe "SQLite database adapter" do
  it "configures connection defaults and accepts explicit settings" do
    [{nil, nil}, {123, 0}].each do |(busy_timeout, checkpoint_pages)|
      database = if busy_timeout && checkpoint_pages
                   Sqlite.open_database(":memory:", busy_timeout_ms: busy_timeout, wal_autocheckpoint_pages: checkpoint_pages)
                 else
                   Sqlite.open_database(":memory:")
                 end
      begin
        database.get("PRAGMA busy_timeout").should eq({"timeout" => busy_timeout || 5_000})
        database.get("PRAGMA wal_autocheckpoint").should eq({"wal_autocheckpoint" => checkpoint_pages || 1_000})
        database.get("PRAGMA synchronous").should eq({"synchronous" => 1})
      ensure
        database.close
      end
    end
  end

  it "opens a file database in WAL mode, creating its directory" do
    directory = File.tempname("chord-sqlite")
    path = File.join(directory, "nested", "state.db")
    begin
      database = Sqlite.open_database(path)
      database.get("PRAGMA journal_mode").should eq({"journal_mode" => "wal"})
      database.exec("CREATE TABLE kept (value TEXT)")
      database.run("INSERT INTO kept (value) VALUES (?)", "durable")
      database.close
      reopened = Sqlite.open_database(path)
      reopened.get("SELECT value FROM kept").should eq({"value" => "durable"})
      reopened.close
    ensure
      FileUtils.rm_rf(directory)
    end
  end

  it "binds and returns every portable value type" do
    database = Sqlite.open_database(":memory:")
    database.exec("CREATE TABLE value_probe (i INTEGER, r REAL, t TEXT, b BLOB, n TEXT)")
    database.run("INSERT INTO value_probe VALUES (?, ?, ?, ?, ?)", 7, 1.5, "text", Bytes[1, 2, 3], nil)
    database.get("SELECT * FROM value_probe").should eq({"i" => 7_i64, "r" => 1.5, "t" => "text", "b" => Bytes[1, 2, 3], "n" => nil})
    database.get("SELECT * FROM value_probe WHERE i = ?", 8).should be_nil
    database.close
  end

  it "runs every statement of SQL text passed to exec" do
    database = Sqlite.open_database(":memory:")
    database.exec("CREATE TABLE multi (value INTEGER); INSERT INTO multi VALUES (1); INSERT INTO multi VALUES (2);")
    database.all("SELECT value FROM multi ORDER BY value").should eq [{"value" => 1}, {"value" => 2}]
    expect_raises(SQLite3::Exception, "no such table") { database.exec("SELECT * FROM missing") }
    database.close
  end

  it "commits work done through the transaction handle and closes idempotently" do
    database = Sqlite.open_database(":memory:")
    result = database.transaction do |transaction|
      transaction.exec("CREATE TABLE async_probe (value INTEGER)")
      transaction.run("INSERT INTO async_probe (value) VALUES (?)", 1)
      :done
    end
    result.should eq :done
    database.get("SELECT value FROM async_probe").should eq({"value" => 1})
    database.close
    database.close
    database.closed?.should be_true
    expect_raises(Sqlite::Error, "SQLite database is closed") { database.get("SELECT 1") }
  end

  it "serializes concurrent transactions" do
    database = Sqlite.open_database(":memory:")
    database.exec("CREATE TABLE transaction_queue (value INTEGER)")
    first_started = Channel(Nil).new(1)
    release_first = Channel(Nil).new
    first = Future(Nil).run do
      database.transaction do |transaction|
        transaction.exec("INSERT INTO transaction_queue (value) VALUES (1)")
        first_started.send(nil)
        release_first.receive
      end
      nil
    end
    first_started.receive

    second_started = false
    second = Future(Nil).run do
      database.transaction do |transaction|
        second_started = true
        transaction.exec("INSERT INTO transaction_queue (value) VALUES (2)")
      end
      nil
    end
    Fiber.yield
    second_started.should be_false

    release_first.send(nil)
    first.wait
    second.wait
    database.all("SELECT value FROM transaction_queue ORDER BY value").should eq [{"value" => 1}, {"value" => 2}]
    database.close
  end

  it "runs operations in call order whether they start immediately or wait" do
    database = Sqlite.open_database(":memory:")
    database.exec("CREATE TABLE call_order (value INTEGER)")
    transaction = Future(Nil).run do
      database.transaction do |handle|
        handle.run("INSERT INTO call_order (value) VALUES (?)", 1)
        Fiber.yield
        raise "roll back"
      end
      nil
    end
    before_write = Future(Rows).run { database.all("SELECT value FROM call_order ORDER BY value") }
    write = Future(Nil).run { database.run("INSERT INTO call_order (value) VALUES (?)", 2) }
    after_write = Future(Rows).run { database.all("SELECT value FROM call_order ORDER BY value") }
    expect_raises(Exception, "roll back") { transaction.wait }
    write.wait
    before_write.wait.should be_empty
    after_write.wait.should eq [{"value" => 2}]
    database.close
  end

  it "queues ordinary operations behind an active transaction" do
    database = Sqlite.open_database(":memory:")
    database.exec("CREATE TABLE operation_queue (value INTEGER)")
    transaction_started = Channel(Nil).new(1)
    release_transaction = Channel(Nil).new
    pending = Future(Nil).run do
      database.transaction do |transaction|
        transaction.exec("INSERT INTO operation_queue (value) VALUES (1)")
        transaction_started.send(nil)
        release_transaction.receive
      end
      nil
    end
    transaction_started.receive

    write = Future(Nil).run { database.exec("INSERT INTO operation_queue (value) VALUES (2)") }
    read = Future(Rows).run { database.all("SELECT value FROM operation_queue ORDER BY value") }
    Fiber.yield
    write.settled?.should be_false
    read.settled?.should be_false

    release_transaction.send(nil)
    pending.wait
    write.wait
    read.wait.should eq [{"value" => 1}, {"value" => 2}]
    database.close
  end

  it "queues database calls made by a running transaction behind it" do
    database = Sqlite.open_database(":memory:")
    database.exec("CREATE TABLE barrier_probe (value INTEGER)")
    outside = nil.as(Future(Nil)?)
    transaction = Future(Nil).run do
      database.transaction do |handle|
        outside = Future(Nil).run { database.run("INSERT INTO barrier_probe (value) VALUES (?)", 2) }
        handle.run("INSERT INTO barrier_probe (value) VALUES (?)", 1)
        Fiber.yield
        raise "roll back"
      end
      nil
    end
    expect_raises(Exception, "roll back") { transaction.wait }
    outside.not_nil!.wait
    database.all("SELECT value FROM barrier_probe").should eq [{"value" => 2}]
    database.close
  end

  it "rejects a transaction handle used after its transaction settles" do
    database = Sqlite.open_database(":memory:")
    database.exec("CREATE TABLE stale_probe (value INTEGER)")
    handle = database.transaction do |transaction|
      transaction.run("INSERT INTO stale_probe (value) VALUES (?)", 1)
      transaction
    end
    stale = "SQLite transaction handle is no longer active"
    expect_raises(Sqlite::Error, stale) { handle.exec("INSERT INTO stale_probe (value) VALUES (2)") }
    expect_raises(Sqlite::Error, stale) { handle.run("INSERT INTO stale_probe (value) VALUES (?)", 3) }
    database.all("SELECT value FROM stale_probe").should eq [{"value" => 1}]
    database.close
  end

  it "rolls back and raises the callback error itself" do
    database = Sqlite.open_database(":memory:")
    database.exec("CREATE TABLE rollback_ok (value INTEGER)")
    error = Exception.new("callback failure")
    raised = expect_raises(Exception, "callback failure") do
      database.transaction do |transaction|
        transaction.exec("INSERT INTO rollback_ok (value) VALUES (1)")
        raise error
      end
    end
    raised.should be error
    database.all("SELECT value FROM rollback_ok").should be_empty
    database.close
  end

  it "does not preserve the callback error when rollback itself fails" do
    database = Sqlite.open_database(":memory:")
    database.exec("CREATE TABLE rollback_probe (value INTEGER)")
    aggregate = expect_raises(AggregateError, "SQLite transaction failed and rollback failed") do
      database.transaction do |transaction|
        transaction.exec("INSERT INTO rollback_probe (value) VALUES (1)")
        transaction.exec("COMMIT")
        raise "rejected after an escaped commit"
      end
    end
    aggregate.errors[0].message.should eq "rejected after an escaped commit"
    database.get("SELECT value FROM rollback_probe").should eq({"value" => 1})
    database.close
  end
end
