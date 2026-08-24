# frozen_string_literal: true

# SQLite3, for a Ruby that has no C extensions and no disk to put a database
# on. Hackety Hack uses sqlite for exactly one thing -- HH::Database, which
# stores preferences as key/value rows -- so this implements that shape and
# nothing else, backed by the page's localStorage so preferences survive a
# reload the way the real file does.
#
# Any SQL outside the four statements HH::Database issues raises rather than
# silently doing nothing, so a future use of the database fails where it is
# written instead of somewhere confusing later.
require "js"
require "json"

module SQLite3
  class SQLException < StandardError; end

  class Database
    STORAGE_PREFIX = "hh.sqlite."

    def initialize(path = ":memory:")
      @path = path.to_s
      @tables = load_all
    end

    def execute(sql, *_bind)
      case sql
      when /\ACREATE TABLE IF NOT EXISTS (\w+)/i
        @tables[$1] ||= {}
        []
      when /\ASELECT \* FROM (\w+)/i
        (@tables[$1] || {}).map { |key, value| [key, value] }
      when /\AINSERT OR REPLACE INTO (\w+) \(key,value\) VALUES \("(.*?)", "(.*?)"\)\z/im
        (@tables[$1] ||= {})[$2] = $3
        persist($1)
        []
      when /\ADELETE FROM (\w+) WHERE key = "(.*?)"\z/im
        (@tables[$1] ||= {}).delete($2)
        persist($1)
        []
      else
        raise SQLException, "the wasm sqlite3 shim only understands HH::Database's statements, not: #{sql}"
      end
    end

    def close; end

    private

    def storage
      @storage ||= JS.global[:localStorage]
    end

    def persist(table)
      storage.call(:setItem, STORAGE_PREFIX + table, JSON.generate(@tables[table] || {}))
    rescue StandardError
      nil
    end

    def load_all
      raw = storage.call(:getItem, STORAGE_PREFIX + "preferences")
      return {} if raw.nil? || raw == JS::Null || raw.to_s.empty?

      { "preferences" => JSON.parse(raw.to_s) }
    rescue StandardError
      {}
    end
  end
end
