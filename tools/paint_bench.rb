# frozen_string_literal: true

# Times the document paint of a Shoes program, whichever Clogs backend is in
# play. Load it before the program:
#
#   PAINT_BENCH=out.txt ruby -Iclogs/lib -rtools/paint_bench prog.rb
#
# It reports frame count, total painting time and the per-frame percentiles to
# stderr (or PAINT_BENCH) when the process exits.
require "clogs"

module PaintBench
  class << self
    attr_reader :samples

    def record(seconds)
      (@samples ||= []) << seconds
    end

    def report
      s = (@samples || []).sort
      return if s.empty?

      pct = ->(p) { s[[(s.size * p).to_i, s.size - 1].min] * 1000 }
      label = ENV["PAINT_BENCH_LABEL"] || (Clogs.const_defined?(:Fox) ? "fox" : "libui")
      line = format(
        "%-6s frames=%-5d total=%.3fs mean=%.2fms p50=%.2fms p90=%.2fms max=%.2fms",
        label, s.size, s.sum, s.sum / s.size * 1000, pct.call(0.5), pct.call(0.9), pct.call(0.999)
      )
      if (path = ENV["PAINT_BENCH"])
        File.write(path, line + "\n", mode: "a")
      end
      warn line
    end
  end
end

Clogs::App.prepend(Module.new do
  def on_draw(painter, params)
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    super
  ensure
    PaintBench.record(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t)
  end
end)

at_exit { PaintBench.report }
