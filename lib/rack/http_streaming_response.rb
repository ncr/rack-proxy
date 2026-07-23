# frozen_string_literal: true

require "net_http_hacked"
require "stringio"

module Rack
  # Wraps the hacked net/http in a Rack way.
  class HttpStreamingResponse
    # Raised while streaming when the backend body exceeds max_response_length.
    # The status/headers are already sent, so the transfer is aborted mid-stream.
    class ResponseTooLarge < StandardError; end

    STATUSES_WITH_NO_ENTITY_BODY = {
      204 => true,
      205 => true,
      304 => true
    }.freeze

    attr_accessor :use_ssl, :verify_mode, :read_timeout, :ssl_version, :cert, :key, :logger
    attr_accessor :max_response_length

    # An optional block receives the Net::HTTP instance for configuration before
    # it connects — this is the single source of truth used by Rack::Proxy (see
    # Rack::Proxy#configure_backend_connection). When no block is given, the
    # public accessors above are applied instead (backward-compatible path for
    # direct users of this class).
    def initialize(request, host, port = nil, &configure)
      @request, @host, @port, @configure = request, host, port, configure
    end

    def body
      self
    end

    def code
      response.code.to_i.tap do |response_code|
        STATUSES_WITH_NO_ENTITY_BODY[response_code] && close_connection
      end
    end
    # #status is deprecated
    alias_method :status, :code

    def headers
      Rack::Proxy.build_header_hash(response.to_hash)
    end

    # Can be called only once!
    def each(&block)
      return if connection_closed

      bytes = 0
      response.read_body do |chunk|
        if max_response_length
          bytes += chunk.bytesize
          if bytes > max_response_length
            raise ResponseTooLarge, "backend response exceeded max_response_length=#{max_response_length}"
          end
        end
        block.call(chunk)
      end
    rescue StandardError => e
      # The status/headers are already on the wire, so we can't turn a mid-stream
      # backend failure into a 502. Log it and re-raise so the server aborts the
      # transfer (the client sees a truncated response, not a false "complete").
      logger << "rack-proxy: streaming backend read failed: #{e.class}: #{e.message}\n" if logger.respond_to?(:<<)
      raise
    ensure
      close_connection
    end

    def to_s
      @to_s ||= StringIO.new.tap { |io| each { |line| io << line } }.string
    end

    # Rack calls #close on the response body when it is done with it, including
    # when it bails out early (HEAD, 304, a client disconnect). Without this, a
    # body that is never iterated leaks the backend TCP/TLS connection until GC.
    def close
      close_connection
    end

    protected

    # Net::HTTPResponse
    def response
      @response ||= session.begin_request_hacked(request)
    end

    # Net::HTTP
    def session
      @session ||= Net::HTTP.new(host, port).tap do |http|
        if @configure
          @configure.call(http)
        else
          http.use_ssl = use_ssl
          http.verify_mode = verify_mode
          http.read_timeout = read_timeout
          http.ssl_version = ssl_version if ssl_version
          http.cert = cert if cert
          http.key = key if key
          http.set_debug_output(logger) if logger
        end
        http.start
      end
    end

    private

    attr_reader :request, :host, :port

    attr_accessor :connection_closed

    # Idempotent, best-effort teardown. Uses @session directly (never the lazy
    # #session accessor) so closing a response whose body was never read does not
    # open a connection just to tear it down. Swallows teardown errors: a
    # half-read or already-reset backend must not crash the app or mask the
    # original error.
    def close_connection
      return if connection_closed || @session.nil?

      self.connection_closed = true
      begin
        @session.end_request_hacked
      ensure
        @session.finish if @session.started?
      end
    rescue StandardError
      # best-effort: the connection may already be gone
    end
  end
end
