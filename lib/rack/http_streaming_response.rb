# frozen_string_literal: true

require "net/https"
require "stringio"

module Rack
  # A lazy Rack body that streams a backend Net::HTTP response without
  # buffering it.
  #
  # The request runs inside a Fiber, using only the public block form of
  # Net::HTTP#request: the Fiber pauses (`Fiber.yield res`) the moment the
  # status and headers are available, and #each resumes it to pull body chunks
  # as the server consumes them. This replaced the 2010-era monkey-patch of
  # private net/http internals (`net_http_hacked.rb`, deleted in 1.0) and
  # inherits upstream's handling of 1xx interim responses, keep-alive
  # negotiation, and transport errors.
  #
  # A Fiber can only be resumed from the thread that created it. The request
  # Fiber is created lazily on first use (#code/#headers/#each), so the normal
  # Rack flow — one thread calls the app and then iterates the body — is fine.
  # If #close is called from a different thread (some servers do this on client
  # abort), the Fiber unwind is skipped and the connection is hard-closed
  # instead, which releases the socket either way.
  class HttpStreamingResponse
    # Raised while streaming when the backend body exceeds max_response_length.
    # The status/headers are already sent, so the transfer is aborted mid-stream.
    class ResponseTooLarge < StandardError; end

    # Raised INTO the request Fiber to unwind it on early termination (client
    # abort, HEAD, 204/304, oversize response). Deliberately a direct
    # StandardError subclass — it must never match the network-error classes
    # Net::HTTP#request retries on, or aborting a stream could replay the
    # request against the backend.
    class StreamAborted < StandardError; end

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

      # Forward the backend body verbatim. Without this, Net::HTTP inflates
      # gzip/deflate bodies for requests that opted in (the default for e.g.
      # Net::HTTP::Get), leaving the already-forwarded Content-Length and
      # Content-Encoding describing bytes the client never receives. The old
      # patched read path never decoded; keep that contract.
      if request.instance_variable_defined?(:@decode_content)
        request.instance_variable_set(:@decode_content, false)
      end
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

      response # make sure the request has started and the headers are in

      bytes = 0
      while @fiber.alive?
        chunk = @fiber.resume
        # The last resume returns the Fiber's terminal value, not a body chunk.
        next unless chunk.is_a?(String)

        if max_response_length
          bytes += chunk.bytesize
          if bytes > max_response_length
            raise ResponseTooLarge, "backend response exceeded max_response_length=#{max_response_length}"
          end
        end
        block.call(chunk)
      end
    rescue => e
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

    # Net::HTTPResponse. Fetching it lazily dials the backend, sends the request
    # and reads the response head; the body stays unread on the socket until
    # #each resumes the Fiber.
    def response
      return @response if @response

      # Starting a request on a closed body would dial a connection that
      # nothing can ever release (close_connection has already latched). Check
      # AFTER the memo: #headers is legitimately read after #code auto-closed a
      # 204/304, which must keep working.
      raise IOError, "rack-proxy: backend response was closed before it was read" if connection_closed

      @response = begin
        @fiber = Fiber.new do
          session.request(request) do |res|
            Fiber.yield res
            bytes = 0
            res.read_body do |chunk|
              bytes += chunk.bytesize
              Fiber.yield chunk
            end
            # Net::HTTP tolerates premature EOF for Content-Length bodies on
            # supported Ruby versions. A proxy must signal an incomplete body.
            if request.response_body_permitted? && res.class.body_permitted? && res.content_length && bytes != res.content_length
              raise EOFError, "backend response is shorter than Content-Length"
            end
          end
          :done
        end
        @fiber.resume
      end
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
        # Net::HTTP retries idempotent requests once on transport errors — but a
        # retry after the response was yielded would silently replay the request
        # and restart the body mid-stream. The old patched path never retried;
        # streaming must not either. (Set after the configure block on purpose.)
        http.max_retries = 0
        http.start
      end
    end

    private

    attr_reader :request, :host, :port

    attr_accessor :connection_closed

    # Idempotent, best-effort teardown. Uses @session/@fiber directly (never the
    # lazy accessors) so closing a response that was never read does not dial
    # the backend just to tear it down. A still-suspended request Fiber is
    # unwound first (running net/http's own ensure blocks), then the connection
    # is closed for real. Swallows teardown errors: a half-read or already-reset
    # backend must not crash the app or mask the original error.
    def close_connection
      return if connection_closed

      self.connection_closed = true

      if @fiber&.alive?
        begin
          @fiber.raise(StreamAborted, "backend stream closed before the response was fully read")
        rescue
          # Expected: StreamAborted itself (or whatever the unwind trips over)
          # propagates back out of Fiber#raise; FiberError if another thread
          # owns the Fiber. Either way we fall through to closing the socket.
        end
      end

      begin
        @session.finish if @session&.started?
      rescue
        # best-effort: the connection may already be gone
      end
    end
  end
end
