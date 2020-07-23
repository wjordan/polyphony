# frozen_string_literal: true

module Polyphony
  # Implements a limited resource pool
  class ResourcePool
    attr_reader :limit, :size

    # Initializes a new resource pool
    # @param opts [Hash] options
    # @param &block [Proc] allocator block
    def initialize(opts, &block)
      @allocator = block
      @limit = opts[:limit] || 4
      @size = 0
      @stock = Polyphony::Queue.new
      @acquired_resources = {}
      @acquired_counts = {}
    end

    def available
      @stock.size
    end

    def acquire
      fiber = Fiber.current
      unless (resource = @acquired_resources[fiber])
        @acquired_counts[fiber] = 0
        add_to_stock if @size < @limit && @stock.empty?
        snooze until (resource = @stock.shift)
        @acquired_resources[fiber] = resource
      end
      @acquired_counts[fiber] += 1

      yield resource
    ensure
      if resource
        if (@acquired_counts[fiber] -= 1) == 0
          @acquired_counts.delete(fiber)
          if @acquired_resources.delete(fiber) == resource
            @stock.push resource
          end
        end
      end
    end

    def method_missing(sym, *args, &block)
      acquire { |r| r.send(sym, *args, &block) }
    end

    def respond_to_missing?(*_args)
      true
    end

    # Allocates a resource
    # @return [any] allocated resource
    def add_to_stock
      @size += 1
      @stock << @allocator.call
    end

    def discard
      @size -= 1
      @acquired_resources.delete(Fiber.current)
    end

    def preheat!
      add_to_stock while @size < @limit
    end
  end
end
