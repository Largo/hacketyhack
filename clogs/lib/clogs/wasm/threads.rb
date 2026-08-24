# frozen_string_literal: true

module Clogs
  module Wasm
    # Threads, for a Ruby that has none.
    #
    # wasm CRuby is single-threaded: `Thread.new` raises NotImplementedError.
    # Shoes 3 programs use threads freely -- Hackety Hack's own turtle runs the
    # user's drawing in one so the window stays alive while it steps -- so
    # without something here a whole style of Shoes program is simply out.
    #
    # Fibers do work, and what those programs actually want is not parallelism
    # but a second flow of control that yields at `sleep`. So this is a green
    # thread: a Fiber, plus a scheduler that Runtime#tick drives between
    # frames. `sleep` inside one suspends that flow and lets the frame finish,
    # which is what the program meant; `sleep` outside one is left alone.
    #
    # What this deliberately is not is pre-emptive. A green thread that never
    # sleeps and never returns will hang the page exactly as an infinite loop
    # in an event handler would, because it is the same thread.
    module GreenThreads
      module_function

      def threads
        @threads ||= []
      end

      def current
        @current
      end

      def spawn(*args, &block)
        thread = GreenThread.new(args, block)
        threads << thread
        thread
      end

      # Called once per frame. Resumes every green thread whose wake time has
      # passed, in creation order, and drops the ones that have finished.
      def run_pending(now_ms)
        return false if threads.empty?

        ran = false
        threads.dup.each do |thread|
          next unless thread.ready?(now_ms)

          ran = true
          previous = @current
          @current = thread
          begin
            thread.resume(now_ms)
          ensure
            @current = previous
          end
          threads.delete(thread) unless thread.alive?
        end
        ran
      end

      # Suspend the running green thread. Returns to the scheduler, which will
      # resume it no earlier than `seconds` from now.
      def sleep(seconds = nil)
        thread = @current
        return nil unless thread

        thread.wake_at = seconds.nil? ? Float::INFINITY : Runtime.now + (seconds.to_f * 1000)
        Fiber.yield
        seconds
      end

      def pass
        return nil unless @current

        @current.wake_at = 0
        Fiber.yield
        nil
      end

      # A running green thread, with as much of Thread's interface as Shoes
      # programs are actually observed to use.
      class GreenThread
        attr_accessor :wake_at
        attr_reader :value

        def initialize(args, block)
          @wake_at = 0
          @locals = {}
          @alive = true
          @fiber = Fiber.new do
            @value = block.call(*args)
            @alive = false
          end
        end

        def ready?(now_ms)
          @alive && @wake_at <= now_ms
        end

        def resume(_now_ms)
          return unless @alive

          @fiber.resume
          @alive = false unless @fiber.alive?
        rescue StandardError => e
          @alive = false
          Clogs::App.report_error(e)
        end

        def alive?
          @alive
        end

        def status
          @alive ? "sleep" : false
        end

        # Waiting for another flow of control only means something from inside
        # one. From the main flow there is nothing to wait *in*: returning
        # immediately is the honest answer, and the alternative is a page that
        # never paints again.
        def join(_limit = nil)
          if GreenThreads.current
            GreenThreads.pass while @alive
          else
            warn "Clogs: Thread#join outside a thread cannot block in wasm; returning immediately"
          end
          self
        end

        def kill
          @alive = false
          self
        end
        alias_method :exit, :kill
        alias_method :terminate, :kill

        def [](key)
          @locals[key]
        end

        def []=(key, value)
          @locals[key] = value
        end

        def name
          @name
        end

        attr_writer :name

        def abort_on_exception=(_value); end
      end
    end
  end
end

# A queue is how a Shoes program hands work to its background thread, and
# Hackety Hack's turtle is exactly that: the drawing runs in a thread that
# blocks on `Queue#pop` until a button pushes the next command in. Blocking
# there is what the real implementation does, and with one thread it is a
# deadlock -- fatal, not rescuable. Only `pop` needs replacing: everything is
# single-threaded, so `empty?` cannot go stale between the check and the take,
# and the non-blocking pop underneath is guaranteed to succeed.
class Thread
  class Queue
    alias_method :clogs_wasm_blocking_pop, :pop

    def pop(non_block = false)
      while empty?
        raise ThreadError, "queue empty" if non_block

        unless Clogs::Wasm::GreenThreads.current
          # Nothing to wait in. Blocking the main flow would freeze the page
          # for good, so this reports and gives up rather than hanging.
          warn "Clogs: Queue#pop outside a thread cannot block in wasm; returning nil"
          return nil
        end

        Clogs::Wasm::GreenThreads.pass
      end

      clogs_wasm_blocking_pop(true)
    end
    alias_method :shift, :pop
    alias_method :deq, :pop
  end
end

# The real Thread class is present in wasm but raises the moment it is asked to
# start anything, so only the entry points are replaced. Thread.current and
# everything else about the one real thread keep working.
class Thread
  class << self
    def new(*args, &block)
      raise ThreadError, "must be called with a block" unless block

      Clogs::Wasm::GreenThreads.spawn(*args, &block)
    end
    alias_method :start, :new
    alias_method :fork, :new

    def pass
      Clogs::Wasm::GreenThreads.current ? Clogs::Wasm::GreenThreads.pass : nil
    end
  end
end

module Kernel
  alias_method :clogs_wasm_blocking_sleep, :sleep

  # Cooperative inside a green thread, unchanged outside it. Outside, `sleep`
  # in a browser blocks the frame -- that is what it means -- and a Shoes
  # program that does it at the top level gets the behaviour it asked for.
  def sleep(seconds = nil)
    return Clogs::Wasm::GreenThreads.sleep(seconds) if Clogs::Wasm::GreenThreads.current

    seconds.nil? ? clogs_wasm_blocking_sleep : clogs_wasm_blocking_sleep(seconds)
  end
  private :sleep
end
