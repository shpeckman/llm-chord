# src/llm/chord/sqlite/migrations.cr
module LLM::Chord::Sqlite
  record Migration, version : Int32, statements : Array(String)

  def self.apply_migrations(database : Database, migrations : Array(Migration), *, table : String) : Nil
    validate_schema_prefix(table)
    migrations.each_with_index do |migration, index|
      unless migration.version == index + 1
        raise Error.new("SQLite migrations must have contiguous versions starting at 1")
      end
    end
    database.transaction do |transaction|
      transaction.exec(<<-SQL)
        CREATE TABLE IF NOT EXISTS #{table} (
          singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
          version INTEGER NOT NULL CHECK (version >= 0)
        ) STRICT
        SQL
      transaction.run("INSERT OR IGNORE INTO #{table} (singleton, version) VALUES (1, 0)")
      row = transaction.get("SELECT version FROM #{table} WHERE singleton = 1")
      raise Error.new("SQLite schema metadata is missing") unless row
      applied = row["version"].as(Int64)
      current = migrations.last?.try(&.version) || 0
      if applied > current
        raise Error.new("SQLite schema version #{applied} is newer than supported version #{current}")
      end
      migrations.each do |migration|
        next if migration.version <= applied
        migration.statements.each { |statement| transaction.exec(statement) }
        transaction.run("UPDATE #{table} SET version = ? WHERE singleton = 1", migration.version)
      end
    end
  end
end
