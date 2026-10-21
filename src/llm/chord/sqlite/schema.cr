# src/llm/chord/sqlite/schema.cr
module LLM::Chord::Sqlite
  SCHEMA_PREFIX = /\A[A-Za-z_][A-Za-z0-9_]*\z/

  def self.validate_schema_prefix(prefix : String) : Nil
    quoted = Schema.stringify(JSON::Any.new(prefix))
    raise Error.new("Invalid SQLite schema prefix #{quoted}") unless SCHEMA_PREFIX.matches?(prefix)
    raise Error.new("SQLite schema prefix #{quoted} is reserved") if prefix.downcase.starts_with?("sqlite_")
  end
end
