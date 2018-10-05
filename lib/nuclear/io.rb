# frozen_string_literal: true

export_default :IO

Core        = import('./core')
Stream      = import('./stream')
LineReader  = import('./line_reader')

# Methods for watching an io
module Watching
  # Registers the underlying IO with the default reactor
  # @return [void]
  def watch_io
    create_watcher(@io, true, false)
  end

  # Unregisters io with default reactor, removes monitor
  # return [void]
  def remove_watcher
    @watcher_r.cancel
    @watcher_r = nil

    @watcher_w.cancel
    @watcher_w = nil
  end

  def create_watcher(io, read, write)
    @watcher_r = EV::IO.new(io, :r, read) { read_from_io }
    @watcher_w = EV::IO.new(io, :w, write) { write_to_io }
  end

  # Filters intersts according to options
  # @param interests [Symbol] one of :r, :rw, :w
  # @return [Symbol] one of :r, :rw, :w
  def filter_event_mask(mask)
    return mask unless @opts[:write_only]
    case mask
    when :r   then nil
    when :rw  then :w
              else mask
    end
  end
end

# Methods for reading and writing to underlying IO
module ReadWrite
  # Writes data to the IO, returning a promise that will complete once the
  # write buffer is drained
  # @param data [String] data be written
  # @return [Promise]
  def write(data)
    Core.promise do |p|
      @callbacks[:drain] = proc { p.resolve(true) }
      self << data
      @callbacks[:drain] = nil
    end
  end

  # Creates a promise that will complete once data is available for reading
  # @return [Promise]
  def read
    Core.promise do |p|
      @callbacks[:data] = proc do |data|
        @callbacks[:data] = nil
        p.(data)
      end
    end
  end

  READ_MAX_CHUNK_SIZE = 2**20
  NO_EXCEPTION_OPTS = { exception: false }.freeze

  # Reads asynchronously from the underlying IO, triggering the :data callback
  # when data is available
  # @return [void]
  def read_from_io
    while @io
      result = @io.read_nonblock(READ_MAX_CHUNK_SIZE, @read_buf, NO_EXCEPTION_OPTS)
      break unless handle_read_result(result)
    end
  rescue StandardError => e
    close_on_error(e)
  end

  # Handles result of reading from underlying IO. Returns true if reading
  # should continue.
  # @param result [Integer, Symbol, nil] result of call to IO#read_nonblock
  # @return [Boolean] true if writing should continue
  def handle_read_result(result)
    case result
    when nil
      connection_was_closed
      false
    when :wait_readable
      false
    else
      @callbacks[:data]&.(result)
      true
    end
  end

  # Writes from the write buffer to the underlying IO, triggering the :drain
  # callback once all pending data has been written
  # @return [void]
  def write_to_io
    while @io
      result = @io.write_nonblock(@write_buffer, exception: false)
      break unless handle_write_result(result)
    end
  rescue StandardError => e
    close_on_error(e)
  end

  # Handles result of writing to underlying IO. Returns true if writing should
  # continue.
  # @param result [Integer, Symbol, nil] result of call to IO#write_nonblock
  # @return [Boolean] true if writing should continue
  def handle_write_result(result)
    case result
    when :wait_writable
      @watcher_w.start
      false
    when nil
      connection_was_closed
      false
    else
      slice_write_buffer(result)
    end
  end

  # Slices write buffer, returns true if more left to write. If the write
  # buffer is empty after being sliced, the :drain callback is triggered
  # @param written [Integer] amount of bytes written
  # @return [Boolean] true if write buffer is not empty
  def slice_write_buffer(written)
    if written == @write_buffer.bytesize
      @watcher_w.stop
      @write_buffer.clear
      @callbacks[:drain]&.()
      false
    else
      @write_buffer.slice!(0, written)
      true
    end
  end

  # Writes data to the IO
  # @param data [String] data to be written
  # @return [void]
  def <<(data)
    @write_buffer << data
    write_to_io
  end
end

# Wraps a plain IO object with stream capabilities
class IO < Stream
  # Creates a line reader from the given IO
  # @param io [IO] IO (wrapped) object
  # @return [LineReader]
  def self.lines(io)
    LineReader.new(io).lines
  end

  # Creates an IO from STDIN
  # @return [IO]
  def self.stdin
    @stdin ||= new(STDIN)
  end

  # Creates an IO from STDOUT
  # @return [IO]
  def self.stdout
    @stdout ||= new(STDOUT, write_only: true)
  end

  include Watching
  include ReadWrite

  # Initializes an IO
  # @param io [::IO] plain IO object
  # @param opts [Hash] options
  def initialize(io, opts = {})
    super(opts)
    @io = io
    @open = io
    @read_buf = (+"")
    watch_io if io && opts[:watch] != false
  end

  # Returns raw (plain) IO object
  # @return [::IO]
  def raw_io
    @io
  end

  # Handles error raised while interacting with the underlying IO
  # @param err [Exception] raised error
  # @return [void]
  def close_on_error(err)
    case err
    when OpenSSL::OpenSSLError, SystemCallError
      # do nothing
    else
      puts "error: #{err.inspect}"
      puts err.backtrace.join("\n")
      @callbacks[:error]&.(err)
    end
    close
  end

  # Called if the connection was closed while reading or writing
  # @return [void]
  def connection_was_closed
    close
  end

  # Closes the underlying IO and cleans up
  def close
    return unless @io

    cleanup_io
    cleanup_buffers

    @callbacks[:close]&.()
    @callbacks.clear
  rescue StandardError => e
    puts "error while closing: #{e}"
    puts e.backtrace.join("\n")
  end

  def cleanup_io
    remove_watcher
    @io.close
    @io = nil
    @open = false
    @connected = false
  end

  def cleanup_buffers
    @read_buffer = nil
    @write_buffer = nil
  end
end