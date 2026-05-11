require "timeout"

# Centralized service for matching source IDs against ignore patterns.
# Extracts exact matches (^id$) from regex patterns for O(1) lookups.
#
# Usage:
#   matcher = IgnoreMatcher.for(source: "airtable")
#   matcher.match?("base123")  # => true/false
#
# Returns a matcher object with:
#   - exact: Set of exact match IDs (extracted from ^id$ patterns)
#   - regexps: Array of compiled Regexp objects for pattern matching
#   - match?(source_id): Time-boxed matching method
class IgnoreMatcher
  MAX_PATTERN_LENGTH = 200
  REGEX_TIMEOUT_SECONDS = 0.01 # 10ms timeout for regex evaluation

  # Pattern like ^exact_id$ can be extracted as exact match
  # But only if it doesn't contain regex special characters
  EXACT_PATTERN_REGEX = /\A\^(.+)\$\z/
  # Regex special characters that indicate it's not a pure exact match
  REGEX_SPECIAL_CHARS = /[.*+?^$|\\\[\]{}()]/

  attr_reader :exact, :regexps, :ignore_records

  # Factory method: create a matcher for the given source
  # @param source [String] The source name (e.g., "airtable")
  # @return [IgnoreMatcher] A matcher instance with exact matches and regexps
  def self.for(source:)
    ignores = SyncSourceIgnore.where(source: source).to_a
    new(ignores)
  end

  def initialize(ignore_records)
    @ignore_records = ignore_records
    @exact = Set.new
    @exact_ignore_map = {} # Map exact ID to ignore records
    @regexps = []
    @regex_ignore_map = {} # Map regex index to ignore record

    ignore_records.each do |ignore|
      next unless ignore.source_id.present?
      next if ignore.source_id.length > MAX_PATTERN_LENGTH

      # Check if pattern is an exact match pattern (^id$)
      # Only treat as exact if it matches ^id$ format AND doesn't contain regex special chars
      if (match = ignore.source_id.match(EXACT_PATTERN_REGEX))
        exact_id = match[1]
        # If the extracted ID contains regex special characters, treat as regex pattern
        if exact_id.match?(REGEX_SPECIAL_CHARS)
          # Store as regex pattern instead
          begin
            compiled_regex = Regexp.new(ignore.source_id)
            regex_index = @regexps.length
            @regexps << compiled_regex
            @regex_ignore_map[regex_index] = ignore
          rescue RegexpError => e
            Rails.logger.error("Invalid regex pattern in SyncSourceIgnore##{ignore.id}: #{ignore.source_id} - #{e.message}")
          end
        else
          # Pure exact match - no regex special characters
          @exact.add(exact_id)
          @exact_ignore_map[exact_id] ||= []
          @exact_ignore_map[exact_id] << ignore
        end
      else
        # Store compiled regex pattern
        begin
          compiled_regex = Regexp.new(ignore.source_id)
          regex_index = @regexps.length
          @regexps << compiled_regex
          @regex_ignore_map[regex_index] = ignore
        rescue RegexpError => e
          Rails.logger.error("Invalid regex pattern in SyncSourceIgnore##{ignore.id}: #{ignore.source_id} - #{e.message}")
          # Skip invalid patterns
        end
      end
    end
  end

  # Check if a source_id matches any ignore pattern
  # Uses O(1) exact match lookup first, then falls back to regex patterns
  # @param source_id_to_check [String] The source ID to check
  # @return [Boolean] true if matched, false otherwise
  def match?(source_id_to_check)
    source_id_str = source_id_to_check.to_s

    # O(1) check for exact matches first
    return true if @exact.include?(source_id_str)

    # O(R) check regex patterns only if not an exact match
    @regexps.each do |regex|
      begin
        Timeout.timeout(REGEX_TIMEOUT_SECONDS) do
          return true if regex.match?(source_id_str)
        end
      rescue Timeout::Error
        Rails.logger.warn("IgnoreMatcher regex timed out (possible DoS): #{regex.inspect}")
        # Continue checking other patterns
      end
    end

    false
  end

  # Find all ignore records that match the given source_id
  # @param source_id_to_check [String] The source ID to check
  # @return [Array<SyncSourceIgnore>] Array of matching ignore records
  def matching_ignores(source_id_to_check)
    source_id_str = source_id_to_check.to_s
    matches = []

    # Check exact matches (O(1) lookup)
    if @exact.include?(source_id_str)
      matches.concat(@exact_ignore_map[source_id_str] || [])
    end

    # Check regex patterns
    @regexps.each_with_index do |regex, index|
      ignore = @regex_ignore_map[index]
      next unless ignore

      begin
        Timeout.timeout(REGEX_TIMEOUT_SECONDS) do
          matches << ignore if regex.match?(source_id_str)
        end
      rescue Timeout::Error
        Rails.logger.warn("IgnoreMatcher regex timed out (possible DoS): #{ignore.source_id}")
        # Skip this pattern
      end
    end

    matches.uniq
  end
end
