# frozen_string_literal: true

require 'fiber'

require_relative '../core/exceptions'

module Polyphony
  # Fiber control API
  module FiberControl
    def await
      if @running == false
        return @result.is_a?(Exception) ? (Kernel.raise @result) : @result
      end

      fiber = Fiber.current
      @waiting_fibers ||= {}
      @waiting_fibers[fiber] = true
      suspend
    ensure
      @waiting_fibers&.delete(fiber)
    end
    alias_method :join, :await

    def interrupt(value = nil)
      return if @running == false

      schedule Polyphony::MoveOn.new(value)
    end
    alias_method :stop, :interrupt

    def restart(value = nil)
      raise "Can''t restart main fiber" if @main

      if @running
        schedule Polyphony::Restart.new(value)
        return self
      end

      parent.spin(@tag, @caller, &@block).tap do |f|
        f.schedule(value) unless value.nil?
      end
    end
    alias_method :reset, :restart

    def cancel
      return if @running == false

      schedule Polyphony::Cancel.new
    end

    def terminate
      return if @running == false

      schedule Polyphony::Terminate.new
    end

    def raise(*args)
      error = error_from_raise_args(args)
      schedule(error)
    end

    def error_from_raise_args(args)
      case (arg = args.shift)
      when String then RuntimeError.new(arg)
      when Class  then arg.new(args.shift)
      when Exception then arg
      else RuntimeError.new
      end
    end
  end

  # Fiber supervision
  module FiberSupervision
    def supervise(opts = {})
      @counter = 0
      @on_child_done = proc do |fiber, result|
        self << fiber unless result.is_a?(Exception)
      end
      loop { supervise_perform(opts) }
    ensure
      @on_child_done = nil
    end

    def supervise_perform(opts)
      fiber = receive
      restart_fiber(fiber, opts) if fiber
    rescue Polyphony::Restart
      restart_all_children
    rescue Exception => e
      Kernel.raise e if e.source_fiber.nil? || e.source_fiber == self

      restart_fiber(e.source_fiber, opts)
    end

    def restart_fiber(fiber, opts)
      opts[:watcher]&.send [:restart, fiber]
      case opts[:restart]
      when true
        fiber.restart
      when :one_for_all
        @children.keys.each(&:restart)
      end
    end
  end

  # Class methods for controlling fibers (namely await and select)
  module FiberControlClassMethods
    def await(*fibers)
      return [] if fibers.empty?

      state = setup_await_select_state(fibers)
      await_setup_monitoring(fibers, state)
      suspend
      fibers.map(&:result)
    ensure
      await_select_cleanup(state)
    end
    alias_method :join, :await

    def setup_await_select_state(fibers)
      {
        awaiter: Fiber.current,
        pending: fibers.each_with_object({}) { |f, h| h[f] = true }
      }
    end

    def await_setup_monitoring(fibers, state)
      fibers.each do |f|
        f.when_done { |r| await_fiber_done(f, r, state) }
      end
    end

    def await_fiber_done(fiber, result, state)
      state[:pending].delete(fiber)

      if state[:cleanup]
        state[:awaiter].schedule if state[:pending].empty?
      elsif !state[:done] && (result.is_a?(Exception) || state[:pending].empty?)
        state[:awaiter].schedule(result)
        state[:done] = true
      end
    end

    def await_select_cleanup(state)
      return if state[:pending].empty?

      terminate = Polyphony::Terminate.new
      state[:cleanup] = true
      state[:pending].each_key { |f| f.schedule(terminate) }
      suspend
    end

    def select(*fibers)
      state = setup_await_select_state(fibers)
      select_setup_monitoring(fibers, state)
      suspend
    ensure
      await_select_cleanup(state)
    end

    def select_setup_monitoring(fibers, state)
      fibers.each do |f|
        f.when_done { |r| select_fiber_done(f, r, state) }
      end
    end

    def select_fiber_done(fiber, result, state)
      state[:pending].delete(fiber)
      if state[:cleanup]
        # in cleanup mode the selector is resumed if no more pending fibers
        state[:awaiter].schedule if state[:pending].empty?
      elsif !state[:selected]
        # first fiber to complete, we schedule the result
        state[:awaiter].schedule([fiber, result])
        state[:selected] = true
      end
    end
  end

  # Messaging functionality
  module FiberMessaging
    def <<(value)
      @mailbox << value
    end
    alias_method :send, :<<

    def receive
      @mailbox.shift
    end

    def receive_pending
      @mailbox.shift_all
    end
  end

  # Methods for controlling child fibers
  module ChildFiberControl
    def children
      (@children ||= {}).keys
    end

    def spin(tag = nil, orig_caller = Kernel.caller, &block)
      f = Fiber.new { |v| f.run(v) }
      f.prepare(tag, block, orig_caller, self)
      (@children ||= {})[f] = true
      f
    end

    def child_done(child_fiber, result)
      @children.delete(child_fiber)
      @on_child_done&.(child_fiber, result)
    end

    def terminate_all_children
      return unless @children

      e = Polyphony::Terminate.new
      @children.each_key { |c| c.raise e }
    end

    def await_all_children
      return unless @children && !@children.empty?

      @results = @children.dup
      @on_child_done = proc do |c, r|
        @results[c] = r
        self.schedule if @children.empty?
      end
      suspend
      @on_child_done = nil
      @results.values
    end

    def shutdown_all_children
      terminate_all_children
      await_all_children
    end
  end

  # Fiber life cycle methods
  module FiberLifeCycle
    def prepare(tag, block, caller, parent)
      @thread = Thread.current
      @tag = tag
      @parent = parent
      @caller = caller
      @block = block
      @mailbox = Polyphony::Queue.new
      __fiber_trace__(:fiber_create, self)
      schedule
    end

    def run(first_value)
      setup first_value
      result = @block.(first_value)
      finalize result
    rescue Polyphony::Restart => e
      restart_self(e.value)
    rescue Polyphony::MoveOn, Polyphony::Terminate => e
      finalize e.value
    rescue Exception => e
      e.source_fiber = self
      finalize e, true
    end

    def setup(first_value)
      Kernel.raise first_value if first_value.is_a?(Exception)

      @running = true
    end

    # Performs setup for a "raw" Fiber created using Fiber.new. Note that this
    # fiber is an orphan fiber (has no parent), since we cannot control how the
    # fiber terminates after it has already been created. Calling #setup_raw
    # allows the fiber to be scheduled and to receive messages.
    def setup_raw
      @thread = Thread.current
      @mailbox = Polyphony::Queue.new
    end

    def setup_main_fiber
      @main = true
      @tag = :main
      @thread = Thread.current
      @running = true
      @children&.clear
      @mailbox = Polyphony::Queue.new
    end

    def restart_self(first_value)
      @mailbox = Polyphony::Queue.new
      @when_done_procs = nil
      @waiting_fibers = nil
      run(first_value)
    end

    def finalize(result, uncaught_exception = false)
      result, uncaught_exception = finalize_children(result, uncaught_exception)
      __fiber_trace__(:fiber_terminate, self, result)
      @result = result
      @running = false
      inform_dependants(result, uncaught_exception)
    ensure
      Thread.current.switch_fiber
    end

    # Shuts down all children of the current fiber. If any exception occurs while
    # the children are shut down, it is returned along with the uncaught_exception
    # flag set. Otherwise, it returns the given arguments.
    def finalize_children(result, uncaught_exception)
      begin
        shutdown_all_children
      rescue Exception => e
        result = e
        uncaught_exception = true
      end
      [result, uncaught_exception]
    end

    def inform_dependants(result, uncaught_exception)
      @parent&.child_done(self, result)
      @when_done_procs&.each { |p| p.(result) }
      @waiting_fibers&.each_key do |f|
        f.schedule(result)
      end
      return unless uncaught_exception && !@waiting_fibers

      # propagate unaught exception to parent
      @parent&.schedule(result)
    end

    def when_done(&block)
      @when_done_procs ||= []
      @when_done_procs << block
    end
  end
end

# Fiber extensions
class ::Fiber
  prepend Polyphony::FiberControl
  include Polyphony::FiberSupervision
  include Polyphony::FiberMessaging
  include Polyphony::ChildFiberControl
  include Polyphony::FiberLifeCycle

  extend Polyphony::FiberControlClassMethods

  attr_accessor :tag, :thread, :parent
  attr_reader :result

  def running?
    @running
  end

  def inspect
    "#<Fiber:#{object_id} #{location} (#{state})>"
  end
  alias_method :to_s, :inspect

  def location
    @caller ? @caller[0] : '(root)'
  end

  def caller
    spin_caller = @caller || []
    if @parent
      spin_caller + @parent.caller
    else
      spin_caller
    end
  end

  def main?
    @main
  end
end

Fiber.current.setup_main_fiber
