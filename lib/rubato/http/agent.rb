# frozen_string_literal: true

export_default :Agent

require 'uri'
require 'http/parser'
require 'http/2'
require 'json'

ResourcePool = import('../resource_pool')

module ResponseMixin
  def body
    self[:body]
  end

  def json
    @json ||= ::JSON.parse(self[:body])
  end
end

# Implements an HTTP agent
class Agent
  def self.get(url, query = nil)
    default.get(url, query)
  end

  def self.post(url, query = nil)
    default.post(url, query)
  end

  def self.default
    @default ||= new
  end

  def initialize(max_conns = 6)
    @pools = Hash.new do |h, k|
      h[k] = ResourcePool.new(limit: max_conns) { {} }
    end
  end

  def get(url, query = nil)
    request(url, method: :GET, query: query)
  end

  def post(url, query = nil)
    request(url, method: :POST, query: query)
  end

  S_LOCATION = 'Location'

  OPTS_DEFAULT = {}.freeze

  def request(url, opts = OPTS_DEFAULT)
    ctx = request_ctx(url, opts)
    response = do_request(ctx)

    case response[:status_code]
    when 301, 302
      request(response[:headers][S_LOCATION])
    when 200, 204
      response.extend(ResponseMixin)
    else
      raise "Error received from server: #{response[:status_code]}"
    end
  end

  def request_ctx(url, opts)
    {
      method: opts[:method] || :GET,
      uri:    url_to_uri(url, opts),
      opts:   opts
    }
  end

  def url_to_uri(url, opts)
    uri = URI(url)
    if opts[:query]
      query = opts[:query].map { |k, v| "#{k}=#{v}" }.join("&")
      if uri.query
        v.query = "#{uri.query}&#{query}"
      else
        uri.query = query
      end
    end
    uri
  end

  def do_request(ctx)
    key = uri_key(ctx[:uri])
    @pools[key].acquire do |state|
      state[:socket] ||=  connect(key)
      state[:protocol_method] ||= protocol_method(state[:socket], ctx)
      send(state[:protocol_method], state, ctx)
    rescue => e
      state[:socket]&.close rescue nil
      state.clear
      raise e
    end
  end

  S_H2 = 'h2'

  def protocol_method(socket, ctx)
    if socket.is_a?(::OpenSSL::SSL::SSLSocket) && (socket.alpn_protocol == S_H2)
      :do_http2
    else
      :do_http1
    end
  end

  def do_http1(state, ctx)
    done = false
    body = +''
    parser = HTTP::Parser.new
    parser.on_message_complete = proc { done = true }
    parser.on_body = proc { |data| body << data }
    request = format_http1_request(ctx)

    state[:socket] << request
    while !done
      parser << state[:socket].read
    end

    {
      protocol:     'http1.1',
      status_code:  parser.status_code,
      headers:      parser.headers,
      body:         body
    }
  end

  def do_http2(state, ctx)
    unless state[:http2_client]
      socket, client = state[:socket], HTTP2::Client.new
      client.on(:frame) {|bytes| socket << bytes }
      state[:http2_client] = client
    end

    stream = state[:http2_client].new_stream # allocate new stream

    headers = {
      ':scheme'     => ctx[:uri].scheme,
      ':method'     => ctx[:method].to_s,
      ':path'       => ctx[:uri].request_uri,
      ':authority'  => [ctx[:uri].host, ctx[:uri].port].join(':'),
    }
    headers.merge!(ctx[:opts][:headers]) if ctx[:opts][:headers]

    if ctx[:opts][:payload]
      stream.headers(headers, end_stream: false)
      stream.data(ctx[:opts][:payload], end_stream: true)
    else
      stream.headers(headers, end_stream: true)
    end

    headers = nil
    body = +''
    done = nil

    stream.on(:headers) { |h| headers = h.to_h }
    stream.on(:data) { |c| body << c }
    stream.on(:close) {
      done = true
      return {
        protocol:     'http1.1',
        status_code:  headers && headers[':status'].to_i,
        headers:      headers || {},
        body:         body
      }
    }

    while data = state[:socket].read
      state[:http2_client] << data
    end
  ensure
    (stream.close rescue nil) unless done
  end

  HTTP1_REQUEST = "%<method>s %<request>s HTTP/1.1\r\nHost: %<host>s\r\n\r\n"

  def format_http1_request(ctx)
    HTTP1_REQUEST % {
      method:   ctx[:method],
      request:  ctx[:uri].request_uri,
      host:     ctx[:uri].host
    }
  end

  def uri_key(uri)
    {
      scheme: uri.scheme,
      host:   uri.host,
      port:   uri.port
    }
  end

  S_HTTP = 'http'
  S_HTTPS = 'https'
  SECURE_OPTS = { secure: true, alpn_protocols: ['h2', 'http/1.1'] }

  def connect(key)
    case key[:scheme]
    when S_HTTP
      Rubato::Net.tcp_connect(key[:host], key[:port])
    when S_HTTPS
      Rubato::Net.tcp_connect(key[:host], key[:port], SECURE_OPTS).tap do |socket|
        socket.post_connection_check(key[:host])
      end
    else
      raise "Invalid scheme #{key[:scheme].inspect}"
    end
  end
end