# src/llm/chord/errors.cr
module LLM::Chord
  class AggregateError < Exception
    getter errors : Array(Exception)

    def initialize(@errors : Array(Exception), message : String)
      super(message)
    end
  end

  enum ErrorCode
    Aborted
    ContractMismatch
    Forbidden
    Gone
    Invalid
    NotInVariant
    NotReady
    Released
    Superseded
    Unavailable
    UpgradeConflict
    UpgradeRequired

    def label : String
      to_s.underscore
    end

    def retryable? : Bool
      superseded? || upgrade_conflict?
    end
  end

  class ChordError < Exception
    getter code : ErrorCode
    getter reason : String?
    getter details : JSON::Any?

    def initialize(@code : ErrorCode, message : String, @reason : String? = nil, @details : JSON::Any? = nil, cause : Exception? = nil)
      prefix = (reason = @reason) && !reason.empty? ? "#{@code.label}/#{reason}" : @code.label
      super("#{prefix}: #{message}", cause)
    end

    def retryable? : Bool
      @code.retryable?
    end
  end

  def self.chord_error?(error : Exception, code : ErrorCode? = nil) : Bool
    error.is_a?(ChordError) && (code.nil? || error.code == code)
  end

  def self.forbidden(message : String = "forbidden") : ChordError
    ChordError.new(ErrorCode::Forbidden, message)
  end

  def self.invalid(reason : String, message : String, details : JSON::Any? = nil) : ChordError
    ChordError.new(ErrorCode::Invalid, message, reason: reason, details: details)
  end

  def self.as_chord_error(error : Exception, context : String) : ChordError
    return error if error.is_a?(ChordError)
    ChordError.new(ErrorCode::Unavailable, "#{context}: #{error.message}", cause: error)
  end

  def self.run_all(steps : Enumerable, message : String) : Nil
    errors = [] of Exception
    steps.each do |step|
      step.call
    rescue error
      errors << error
    end
    raise errors[0] if errors.size == 1
    raise AggregateError.new(errors, message) if errors.size > 1
  end
end
