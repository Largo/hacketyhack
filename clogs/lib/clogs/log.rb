# frozen_string_literal: true

module Clogs
  # Lacci insists on a logging implementation being plugged in before any Shoes
  # object exists. Scarpe ships two (one backed by the `logging` gem, one
  # simple); Clogs has its own so that a packaged app needs no logging
  # dependency at all.
  #
  # Configure with SCARPE_LOG_LEVEL (debug/info/warn/error/fatal) or
  # SCARPE_DEBUG=1.
  class Log
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3, fatal: 4 }.freeze

    def initialize(out = $stderr)
      @out = out
      @level = :warn
    end

    def configure_logger(config)
      level = if ENV["SCARPE_LOG_LEVEL"]
        ENV["SCARPE_LOG_LEVEL"].downcase.to_sym
      elsif config.is_a?(Hash)
        (config["default"] || config[:default] || "warn").to_s.to_sym
      else
        :warn
      end
      @level = LEVELS.key?(level) ? level : :warn
    end

    def logger_for_component(component)
      Logger.new(self, component.to_s)
    end

    def emit(component, level, message)
      return if LEVELS[level] < LEVELS[@level]

      @out.puts("[#{level.to_s.upcase}] #{component}: #{message}")
    end

    # One of these per component, matching the interface Lacci expects.
    class Logger
      def initialize(sink, component)
        @sink = sink
        @component = component
      end

      LEVELS.each_key do |level|
        define_method(level) do |message = nil, &block|
          @sink.emit(@component, level, message || block&.call)
        end
      end
    end
  end
end
