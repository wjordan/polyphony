# frozen_string_literal: true

require 'open3'

# IO class method patches
class ::IO
  class << self
    alias_method :orig_binread, :binread
    def binread(name, length = nil, offset = nil)
      File.open(name, 'rb:ASCII-8BIT') do |f|
        f.seek(offset) if offset
        length ? f.read(length) : f.read
      end
    end

    alias_method :orig_binwrite, :binwrite
    def binwrite(name, string, offset = nil)
      File.open(name, 'wb:ASCII-8BIT') do |f|
        f.seek(offset) if offset
        f.write(string)
      end
    end

    EMPTY_HASH = {}.freeze

    # alias_method :orig_foreach, :foreach
    # def foreach(_name, _sep = $/, _limit = nil, _getline_args = EMPTY_HASH,
    #             &_block)
    #   # IO.orig_read(name).each_line(&block)
    #   raise NotImplementedError

    #   # if sep.is_a?(Integer)
    #   #   sep = $/
    #   #   limit = sep
    #   # end
    #   # File.open(name, 'r') do |f|
    #   #   f.each_line(sep, limit, getline_args, &block)
    #   # end
    # end

    alias_method :orig_read, :read
    def read(name, length = nil, offset = nil, opt = EMPTY_HASH)
      if length.is_a?(Hash)
        opt = length
        length = nil
      end
      File.open(name, opt[:mode] || 'r') do |f|
        f.seek(offset) if offset
        length ? f.read(length) : f.read
      end
    end

    # alias_method :orig_readlines, :readlines
    # def readlines(name, sep = $/, limit = nil, getline_args = EMPTY_HASH)
    #   File.open(name, 'r') do |f|
    #     f.readlines(sep, limit, getline_args)
    #   end
    # end

    alias_method :orig_write, :write
    def write(name, string, offset = nil, opt = EMPTY_HASH)
      File.open(name, opt[:mode] || 'w') do |f|
        f.seek(offset) if offset
        f.write(string)
      end
    end

    alias_method :orig_popen, :popen
    def popen(cmd, mode = 'r')
      return orig_popen(cmd, mode) unless block_given?

      Open3.popen2(cmd) { |_i, o, _t| yield o }
    end
  end
end

# IO instance method patches
class ::IO
  # def each(sep = $/, limit = nil, chomp: nil)
  #   sep, limit = $/, sep if sep.is_a?(Integer)
  # end
  # alias_method :each_line, :each

  # def each_byte
  # end

  # def each_char
  # end

  # def each_codepoint
  # end

  # def getbyte
  # end

  # def getc
  # end

  alias_method :orig_read, :read
  def read(len = nil)
    @read_buffer ||= +''
    result = Thread.current.agent.read(self, @read_buffer, len, true)
    return nil unless result

    already_read = @read_buffer
    @read_buffer = +''
    already_read
  end

  alias_method :orig_readpartial, :read
  def readpartial(len, str = nil)
    @read_buffer ||= +''
    result = Thread.current.agent.read(self, @read_buffer, len, false)
    raise EOFError unless result

    if str
      str << @read_buffer
    else
      str = @read_buffer
    end
    @read_buffer = +''
    str
  end

  alias_method :orig_write, :write
  def write(str, *args)
    Thread.current.agent.write(self, str, *args)
  end

  alias_method :orig_write_chevron, :<<
  def <<(str)
    Thread.current.agent.write(self, str)
    self
  end

  alias_method :orig_gets, :gets
  def gets(sep = $/, _limit = nil, _chomp: nil)
    if sep.is_a?(Integer)
      sep = $/
      _limit = sep
    end
    sep_size = sep.bytesize

    @read_buffer ||= +''

    loop do
      idx = @read_buffer.index(sep)
      return @read_buffer.slice!(0, idx + sep_size) if idx

      data = readpartial(8192)
      @read_buffer << data
    rescue EOFError
      return nil
    end
  end

  # def print(*args)
  # end

  # def printf(format, *args)
  # end

  # def putc(obj)
  # end

  alias_method :orig_puts, :puts
  def puts(*args)
    if args.empty?
      write "\n"
      return
    end

    strs = args.inject([]) do |m, a|
      a = a.to_s
      m << a
      m << "\n" unless a =~ /\n$/
      m
    end
    write *strs
    nil
  end

  # def readbyte
  # end

  # def readchar
  # end

  # def readline(sep = $/, limit = nil, chomp: nil)
  # end

  # def readlines(sep = $/, limit = nil, chomp: nil)
  # end

  alias_method :orig_write_nonblock, :write_nonblock
  def write_nonblock(string, _options = {})
    write(string)
  end

  alias_method :orig_read_nonblock, :read_nonblock
  def read_nonblock(maxlen, buf = nil, _options = nil)
    buf ? readpartial(maxlen, buf) : readpartial(maxlen)
  end

  def read_loop(&block)
    Thread.current.agent.read_loop(self, &block)
  end

  # alias_method :orig_read, :read
  # def read(length = nil, outbuf = nil)
  #   if length
  #     return outbuf ? readpartial(length) : readpartial(length, outbuf)
  #   end

  #   until eof?
  #     outbuf ||= +''
  #     outbuf << readpartial(8192)
  #   end
  #   outbuf
  # end
end
