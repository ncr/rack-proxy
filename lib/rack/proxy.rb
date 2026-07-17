require "net_http_hacked"
require "rack/http_streaming_response"
require "rack/proxy/version"

module Rack

  # Subclass and bring your own #rewrite_request and #rewrite_response
  class Proxy
    HOP_BY_HOP_HEADERS = {
      'connection' => true,
      'keep-alive' => true,
      'proxy-authenticate' => true,
      'proxy-authorization' => true,
      'te' => true,
      'trailer' => true,
      'transfer-encoding' => true,
      'upgrade' => true
    }.freeze

    # Backend/network failures that must surface as 502 Bad Gateway rather than
    # crashing the proxy with a raw 500. Construction- and policy-time failures
    # are mapped separately (400/501/502) in #perform_request.
    BACKEND_ERRORS = [
      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::ECONNABORTED,
      Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EPIPE,
      SocketError,
      Timeout::Error,               # includes Net::OpenTimeout
      Net::ReadTimeout, Net::WriteTimeout,
      IOError,                      # includes EOFError
      OpenSSL::SSL::SSLError,
      Net::ProtocolError            # includes Net::HTTPBadResponse
    ].freeze

    class << self
      def extract_http_request_headers(env)
        headers = env.reject do |k, v|
          !(/^HTTP_[A-Z0-9_\.]+$/ === k) || v.nil?
        end.map do |k, v|
          [reconstruct_header_name(k), v]
        end.then { |pairs| build_header_hash(pairs) }

        # Strip hop-by-hop headers before forwarding. Relaying the client's
        # Connection / TE / Transfer-Encoding (etc.) enables request smuggling
        # and confuses the backend — these are connection-scoped, not end-to-end.
        # Per RFC 7230 §6.1 any field named in the inbound Connection header is
        # itself hop-by-hop for this hop. Use #delete (not #reject!) so the
        # returned HeaderHash's case-insensitive index stays consistent on Rack 2.
        connection_named = headers['Connection'].to_s.downcase.split(/,\s*/).map(&:strip)
        headers.keys.each do |key|
          headers.delete(key) if HOP_BY_HOP_HEADERS[key.downcase] || connection_named.include?(key.downcase)
        end

        x_forwarded_for = (headers['X-Forwarded-For'].to_s.split(/, +/) << env['REMOTE_ADDR']).join(', ')

        headers.merge!('X-Forwarded-For' => x_forwarded_for)
      end

      def normalize_headers(headers)
        mapped = headers.map do |k, v|
          [titleize(k), if v.is_a? Array then v.join("\n") else v end]
        end
        build_header_hash Hash[mapped]
      end

      def build_header_hash(pairs)
        # Pass inherit: false so we only check Rack's own constants — otherwise
        # a top-level ::Headers defined by the host app would falsely match.
        if Rack.const_defined?(:Headers, false)
          # Rack::Headers is only available from Rack 3 onward
          Headers.new.tap { |headers| pairs.each { |k, v| headers[k] = v } }
        else
          # Rack::Utils::HeaderHash is deprecated from Rack 3 onward and is to be removed in 3.1
          Utils::HeaderHash.new(pairs)
        end
      end

      protected

      def reconstruct_header_name(name)
        titleize(name.sub(/^HTTP_/, "").gsub("_", "-"))
      end

      def titleize(str)
        str.split("-").map(&:capitalize).join("-")
      end
    end

    # @option opts [String, URI::HTTP] :backend Backend host to proxy requests to
    def initialize(app = nil, opts= {})
      if app.is_a?(Hash)
        opts = app
        @app = nil
      else
        @app = app
      end

      @streaming = opts.fetch(:streaming, true)
      @backend = opts[:backend] ? URI(opts[:backend]) : nil
      @read_timeout = opts.fetch(:read_timeout, 60)
      @ssl_version = opts[:ssl_version]
      @cert = opts[:cert]
      @key = opts[:key]
      # SSL verification: defaults to VERIFY_PEER (Ruby's Net::HTTP default).
      # Pass ssl_verify_none: true to explicitly disable cert verification, or
      # pass verify_mode: <OpenSSL::SSL::VERIFY_*> for full control.
      @verify_mode = opts[:verify_mode]
      @verify_mode ||= OpenSSL::SSL::VERIFY_NONE if opts[:ssl_verify_none]

      @username = opts[:username]
      @password = opts[:password]

      # Optional logger for Net::HTTP debug output. Accepts anything with a #<< method
      # (e.g. $stdout, a StringIO, or a Ruby Logger instance).
      @logger = opts[:logger]

      @opts = opts
    end

    def call(env)
      rewrite_response(perform_request(rewrite_env(env)))
    end

    # Return modified env
    def rewrite_env(env)
      env
    end

    # Return a rack triplet [status, headers, body]
    def rewrite_response(triplet)
      triplet
    end

    # SSRF guardrail. Override to restrict which backends this proxy may connect
    # to; `backend` responds to #host, #port and #scheme. Return false to refuse,
    # which makes the proxy respond 502. The default allows any backend for
    # backward compatibility — but when no :backend is configured the destination
    # is derived from the client-controlled Host header, so a subclass in that
    # setup SHOULD override this to allowlist expected hosts (or set a fixed
    # :backend). See the README "Security considerations".
    def backend_allowed?(backend)
      true
    end

    protected

    def perform_request(env)
      source_request = Rack::Request.new(env)

      # Everything that can fail on a hostile/unreachable request or backend is
      # mapped to a status code here so the proxy never surfaces a raw 500:
      #   400 malformed request URI, 501 unknown method, 502 backend failure.
      begin
        # Initialize request
        if source_request.fullpath == ""
          full_path = URI.parse(env['REQUEST_URI']).request_uri
        else
          full_path = source_request.fullpath
        end

        request_class = net_http_request_class(source_request.request_method)
        return [501, {}, []] if request_class.nil?

        target_request = request_class.new(full_path)

        # Setup headers
        target_request.initialize_http_header(self.class.extract_http_request_headers(source_request.env))

        # Forward the backend response verbatim: don't let Net::HTTP transparently
        # gzip-decode it, which would leave the forwarded Content-Length describing
        # the compressed size (a body/Content-Length desync). The client decodes
        # its own content-encoding.
        target_request.instance_variable_set(:@decode_content, false) if target_request.instance_variable_defined?(:@decode_content)

        # Setup body
        if target_request.request_body_permitted? && source_request.body
          target_request.body_stream    = source_request.body
          target_request.content_length = source_request.content_length.to_i
          target_request.content_type   = source_request.content_type if source_request.content_type
          target_request.body_stream.rewind if target_request.body_stream.respond_to?(:rewind)
        end

        # Use basic auth if we have to
        target_request.basic_auth(@username, @password) if @username && @password

        backend = env.delete('rack.backend') || @backend || source_request
        return [502, {}, []] unless backend_allowed?(backend)

        use_ssl = backend.scheme == "https" || @cert
        read_timeout = env.delete('http.read_timeout') || @read_timeout

        if @streaming
          # streaming response (the actual network communication is deferred, a.k.a. streamed)
          target_response = HttpStreamingResponse.new(target_request, backend.host, backend.port)
          configure_backend_connection(target_response, use_ssl: use_ssl, read_timeout: read_timeout)
          target_response.logger = @logger if @logger
        else
          http = Net::HTTP.new(backend.host, backend.port)
          configure_backend_connection(http, use_ssl: use_ssl, read_timeout: read_timeout)
          http.set_debug_output(@logger) if @logger

          target_response = http.start do
            http.request(target_request)
          end
        end

        code    = target_response.code
        headers = self.class.normalize_headers(target_response.respond_to?(:headers) ? target_response.headers : target_response.to_hash)
        body    = target_response.body || []
        body    = [body] unless body.respond_to?(:each)
      rescue URI::InvalidURIError
        return [400, {}, []]
      rescue *BACKEND_ERRORS => e
        @logger << "rack-proxy: backend request failed: #{e.class}: #{e.message}\n" if @logger.respond_to?(:<<)
        return [502, {}, []]
      end

      # No entity body for status codes that don't allow one (1xx, 204, 304)
      body = [] if Rack::Utils::STATUS_WITH_NO_ENTITY_BODY[code.to_i]

      # Remove hop-by-hop header fields from the response. Use #delete (not
      # #reject!) so the returned HeaderHash's case-insensitive index stays
      # consistent on Rack 2 for any downstream middleware.
      headers.keys.each { |k| headers.delete(k) if HOP_BY_HOP_HEADERS[k.downcase] }

      [code, headers, body]
    end

    private

    # Resolve the Net::HTTP request class for an HTTP method, or nil if there is
    # no matching Net::HTTP::<Verb> (unknown/unsupported method -> 501).
    def net_http_request_class(method)
      Net::HTTP.const_get(method.capitalize, false)
    rescue NameError
      nil
    end

    # Single source of truth for TLS/timeout setup, applied identically to both
    # the streaming response and the non-streaming Net::HTTP connection so a TLS
    # option (notably the VERIFY_PEER default) can never land on only one path.
    def configure_backend_connection(conn, use_ssl:, read_timeout:)
      conn.use_ssl = use_ssl
      conn.read_timeout = read_timeout
      conn.ssl_version = @ssl_version if @ssl_version
      conn.verify_mode = (@verify_mode || OpenSSL::SSL::VERIFY_PEER) if use_ssl
      conn.cert = @cert if @cert
      conn.key = @key if @key
      conn
    end
  end
end
