# spec/sqlite_migrations_spec.cr
require "./spec_helper"
require "../src/llm-chord/sqlite"

private def migration(version : Int32, statements : Array(String) = [] of String) : Sqlite::Migration
  Sqlite::Migration.new(version, statements)
end

private def with_database(&)
  database = Sqlite.open_database(":memory:")
  begin
    yield database
  ensure
    database.close
  end
end

describe "SQLite migrations" do
  it "tracks independent histories and skips migrations already applied" do
    with_database do |database|
      first = [migration(1, ["CREATE TABLE notes (body TEXT)", "INSERT INTO notes VALUES ('kept')"])]
      Sqlite.apply_migrations(database, first, table: "notes_schema")
      Sqlite.apply_migrations(database, first, table: "notes_schema")
      Sqlite.apply_migrations(database, [] of Sqlite::Migration, table: "other_schema")
      Sqlite.apply_migrations(database, first + [migration(2, ["ALTER TABLE notes ADD COLUMN title TEXT"])], table: "notes_schema")
      database.all("SELECT body, title FROM notes").should eq [{"body" => "kept", "title" => nil}]
      database.get("SELECT version FROM notes_schema").should eq({"version" => 2})
      database.get("SELECT version FROM other_schema").should eq({"version" => 0})
      expect_raises(Sqlite::Error, "SQLite schema version 2 is newer than supported version 1") do
        Sqlite.apply_migrations(database, first, table: "notes_schema")
      end
    end
  end

  it "rejects invalid migration versions before touching the database" do
    with_database do |database|
      [[0], [2], [1, 3], [1, 1]].each do |versions|
        expect_raises(Sqlite::Error, "contiguous versions starting at 1") do
          Sqlite.apply_migrations(database, versions.map { |version| migration(version) }, table: "app_schema")
        end
      end
      database.all("SELECT name FROM sqlite_schema").should be_empty
    end
  end

  it "validates prefixes and migration table identifiers before executing SQL" do
    with_database do |database|
      ["", "1bad", "bad-prefix", "bad; DROP TABLE notes", "sqlite_app", "SQLITE_app", "trailing\n"].each do |prefix|
        expect_raises(Sqlite::Error) { Sqlite.validate_schema_prefix(prefix) }
        expect_raises(Sqlite::Error) { Sqlite.apply_migrations(database, [] of Sqlite::Migration, table: prefix) }
      end
      ["pi_", "_private", "app2"].each { |prefix| Sqlite.validate_schema_prefix(prefix) }
      database.all("SELECT name FROM sqlite_schema").should be_empty
    end
  end

  it "quotes rejected prefixes like JSON.stringify" do
    expect_raises(Sqlite::Error, %(Invalid SQLite schema prefix "bad\\"quote")) { Sqlite.validate_schema_prefix(%(bad"quote)) }
    expect_raises(Sqlite::Error, %(SQLite schema prefix "sqlite_app" is reserved)) { Sqlite.validate_schema_prefix("sqlite_app") }
  end

  it "rolls initial bootstrap and every pending migration back together" do
    with_database do |database|
      failed = [
        migration(1, ["CREATE TABLE migration_first (value TEXT) STRICT", "INSERT INTO migration_first (value) VALUES ('retained')"]),
        migration(2, ["CREATE TABLE migration_second (value TEXT) STRICT", "THIS IS NOT SQL"]),
      ]
      expect_raises(SQLite3::Exception) { Sqlite.apply_migrations(database, failed, table: "app_schema") }
      database.get(
        "SELECT count(*) AS count FROM sqlite_schema WHERE name IN ('app_schema', 'migration_first', 'migration_second')"
      ).should eq({"count" => 0})

      Sqlite.apply_migrations(database, [failed[0], migration(2, ["CREATE TABLE migration_second (value TEXT) STRICT"])], table: "app_schema")
      database.get("SELECT version FROM app_schema WHERE singleton = 1").should eq({"version" => 2})
      database.get("SELECT value FROM migration_first").should eq({"value" => "retained"})
    end
  end
end
