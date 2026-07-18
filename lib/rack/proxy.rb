# frozen_string_literal: true

require "rack"
require "net/https"
require "rack/http_streaming_response"
require "rack/proxy/version"

module Rack
  # Subclass and bring your own #rewrite_request and #rewrite_response
  class Proxy
    HOP_BY_HOP_HEADERS = {
      "connection" => true,
      "keep-alive" => true,
      "proxy-authenticate" => true,
      "proxy-authorization" => true,
      "te" => true,
      "trailer" => true,
      "transfer-encoding" => true,
      "upgrade" => true
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
      Net::ProtocolError,
      # A malformed status line / header block raises these; they subclass
      # StandardError directly, NOT Net::ProtocolError, so list them explicitly
      # or a hostile backend crashes the proxy with a raw 500 instead of a 502.
      Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError
    ].freeze

    class << self
      def extract_http_request_headers(env)
        headers = env.reject do |k, v|
          !(/^HTTP_[A-Z0-9_.]+$/ === k) || v.nil?
        end.map do |k, v|
          [reconstruct_header_name(k), v]
        end.then { |pairs| build_header_hash(pairs) }

        # Strip hop-by-hop headers before forwarding. Relaying the client's
        # Connection / TE / Transfer-Encoding (etc.) enables request smuggling
        # and confuses the backend — these are connection-scoped, not end-to-end.
        # Per RFC 7230 §6.1 any field named in the inbound Connection header is
        # itself hop-by-hop for this hop. Use #delete (not #reject!) so the
        # returned HeaderHash's case-insensitive index stays consistent on Rack 2.
        connection_named = headers["Connection"].to_s.downcase.split(/,\s*/).map(&:strip)
        headers.keys.each do |key|
          headers.delete(key) if HOP_BY_HOP_HEADERS[key.downcase] || connection_named.include?(key.downcase)
        end

        x_forwarded_for = (headers["X-Forwarded-For"].to_s.split(/, +/) << env["REMOTE_ADDR"]).join(", ")

        headers.merge!("X-Forwarded-For" => x_forwarded_for)
      end

      def normalize_headers(headers)
        mapped = headers.map do |k, v|
          [titleize(k), v.is_a?(Array) ? v.join("\n") : v]
        end
        build_header_hash mapped.to_h
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
        titleize(name.sub(/^HTTP_/, "").tr("_", "-"))
      end

      def titleize(str)
        str.split("-").map(&:capitalize).join("-")
      end
    end

    # @option opts [String, URI::HTTP] :backend Backend host to proxy requests to
    def initialize(app = nil, opts = {})
      if app.is_a?(Hash)
        opts = app
        @app = nil
      else
        @app = app
      end

      @streaming = opts.fetch(:streaming, true)
      @backend = opts[:backend] ? URI(opts[:backend]) : nil
      # With no :backend (and no env["rack.backend"]), the destination is
      # derived from the client-controlled Host header. Since 1.0 that dynamic
      # mode is refused (502) unless explicitly opted into, because a bare
      # proxy would otherwise be an open proxy / SSRF pivot (cloud metadata
      # endpoints, loopback, RFC1918). Combine the opt-in with a
      # #backend_allowed? allowlist — see the README "Security considerations".
      @allow_dynamic_backend = opts.fetch(:allow_dynamic_backend, false)
      @read_timeout = opts.fetch(:read_timeout, 60)
      # Connect and per-write deadlines. Without these a slow/hostile backend can
      # stall a thread for Net::HTTP's 60s defaults even with a small read_timeout.
      @open_timeout = opts[:open_timeout]
      @write_timeout = opts[:write_timeout]
      # Optional cap (in bytes) on the backend response size, to bound memory
      # against a hostile/huge backend. Enforced incrementally while streaming and
      # via the declared Content-Length / buffered size otherwise. Default: no cap.
      @max_response_length = opts[:max_response_length]
      # :ssl_version pins an exact protocol and is deprecated (it forbids TLS 1.3);
      # prefer :min_version / :max_version, which map to Net::HTTP#min_version=/#max_version=.
      @ssl_version = opts[:ssl_version]
      @min_version = opts[:min_version]
      @max_version = opts[:max_version]
      @cert = opts[:cert]
      @key = opts[:key]
      # Trust anchors for VERIFY_PEER: :ca_file is a PEM bundle path, :cert_store
      # an OpenSSL::X509::Store. Use these for private-CA backends instead of
      # disabling verification with ssl_verify_none.
      @ca_file = opts[:ca_file]
      @cert_store = opts[:cert_store]
      # SSL verification: defaults to VERIFY_PEER (Ruby's Net::HTTP default).
      # Pass ssl_verify_none: true to explicitly disable cert verification, or
      # pass verify_mode: <OpenSSL::SSL::VERIFY_*> for full control.
      @verify_mode = opts[:verify_mode]
      @verify_mode ||= OpenSSL::SSL::VERIFY_NONE if opts[:ssl_verify_none]

      @username = opts[:username]
      @password = opts[:password]

      # Opt-in request hardening (see README "Security considerations"):
      # :strip_credentials drops Cookie/Authorization from the forwarded
      # request; :replace_x_forwarded_for discards the client-supplied
      # X-Forwarded-For chain and forwards only this hop's REMOTE_ADDR.
      @strip_credentials = opts[:strip_credentials]
      @replace_x_forwarded_for = opts[:replace_x_forwarded_for]

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

    # SSRF guardrail, consulted for EVERY request with the resolved backend
    # (`backend` responds to #host, #port and #scheme). Return false to refuse,
    # which makes the proxy respond 502. The default allows the backend, because
    # by the time this hook runs the destination is either app-configured
    # (:backend / env["rack.backend"]) or the deployment has explicitly passed
    # allow_dynamic_backend: true — override it to pin an allowlist on top:
    #
    #   def backend_allowed?(backend)
    #     %w[api.internal.example.com].include?(backend.host)
    #   end
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
        full_path = if source_request.fullpath == ""
          URI.parse(env["REQUEST_URI"]).request_uri
        else
          source_request.fullpath
        end

        request_class = net_http_request_class(source_request.request_method)
        return [501, {}, []] if request_class.nil?

        target_request = request_class.new(full_path)

        # Setup headers
        request_headers = self.class.extract_http_request_headers(source_request.env)
        if @strip_credentials
          request_headers.delete("Cookie")
          request_headers.delete("Authorization")
        end
        if @replace_x_forwarded_for
          if (remote_addr = env["REMOTE_ADDR"])
            request_headers["X-Forwarded-For"] = remote_addr
          else
            request_headers.delete("X-Forwarded-For")
          end
        end
        target_request.initialize_http_header(request_headers)

        # Forward the backend response verbatim: don't let Net::HTTP transparently
        # gzip-decode it, which would leave the forwarded Content-Length describing
        # the compressed size (a body/Content-Length desync). The client decodes
        # its own content-encoding.
        target_request.instance_variable_set(:@decode_content, false) if target_request.instance_variable_defined?(:@decode_content)

        # Setup body
        if target_request.request_body_permitted? && source_request.body
          target_request.body_stream = source_request.body
          target_request.content_length = source_request.content_length.to_i
          target_request.content_type = source_request.content_type if source_request.content_type
          target_request.body_stream.rewind if target_request.body_stream.respond_to?(:rewind)
        end

        # Use basic auth if we have to
        target_request.basic_auth(@username, @password) if @username && @password

        backend = env.delete("rack.backend") || @backend
        if backend.nil?
          # Dynamic mode: the destination would come from the client-controlled
          # Host header. Refused unless the deployment opted in (SSRF guard).
          unless @allow_dynamic_backend
            if @logger.respond_to?(:<<)
              @logger << "rack-proxy: refusing Host-derived backend #{source_request.host.inspect} " \
                         "(no :backend configured; pass allow_dynamic_backend: true to opt in)\n"
            end
            return [502, {}, []]
          end
          backend = source_request
        end
        return [502, {}, []] unless backend_allowed?(backend)

        use_ssl = backend.scheme == "https" || @cert
        read_timeout = env.delete("http.read_timeout") || @read_timeout

        if @streaming
          # streaming response (the actual network communication is deferred, a.k.a. streamed)
          target_response = HttpStreamingResponse.new(target_request, backend.host, backend.port) do |http|
            configure_backend_connection(http, use_ssl: use_ssl, read_timeout: read_timeout)
          end
          target_response.logger = @logger if @logger
        else
          http = Net::HTTP.new(backend.host, backend.port)
          configure_backend_connection(http, use_ssl: use_ssl, read_timeout: read_timeout)

          target_response = http.start do
            http.request(target_request)
          end
        end

        code = target_response.code
        headers = self.class.normalize_headers(target_response.respond_to?(:headers) ? target_response.headers : target_response.to_hash)
        body = target_response.body || []
        body = [body] unless body.respond_to?(:each)
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

      return [502, {}, []] if response_too_large?(target_response, headers, body)

      [code, headers, body]
    end

    private

    # Enforce :max_response_length. Returns true (→ 502) when the response is
    # already known to be too large. For streaming, a declared oversize is
    # rejected up-front (the connection is closed) and the incremental limit is
    # armed on the body for chunked/unknown-length responses; for non-streaming,
    # the body is already buffered so we check its actual size. Returns false
    # (allow) when no cap is set.
    def response_too_large?(target_response, headers, body)
      return false unless @max_response_length

      declared = headers["Content-Length"]
      declared_oversize = declared && declared.to_i > @max_response_length

      if target_response.respond_to?(:max_response_length=)
        if declared_oversize
          target_response.close
          return true
        end
        target_response.max_response_length = @max_response_length
        false
      else
        buffered = body.sum { |part| part.to_s.bytesize }
        declared_oversize || buffered > @max_response_length
      end
    end

    # Resolve the Net::HTTP request class for an HTTP method, or nil if there is
    # no matching Net::HTTP::<Verb> (unknown/unsupported method -> 501).
    def net_http_request_class(method)
      Net::HTTP.const_get(method.capitalize, false)
    rescue NameError
      nil
    end

    # Single source of truth for TLS/timeout setup, applied to the (real
    # Net::HTTP) connection on both the streaming and non-streaming paths so a
    # TLS option — notably the VERIFY_PEER default — can never land on only one.
    def configure_backend_connection(conn, use_ssl:, read_timeout:)
      conn.use_ssl = use_ssl
      conn.read_timeout = read_timeout
      conn.open_timeout = @open_timeout if @open_timeout
      conn.write_timeout = @write_timeout if @write_timeout

      if use_ssl
        conn.verify_mode = @verify_mode || OpenSSL::SSL::VERIFY_PEER
        conn.ca_file = @ca_file if @ca_file
        conn.cert_store = @cert_store if @cert_store
        conn.min_version = @min_version if @min_version
        conn.max_version = @max_version if @max_version
        conn.ssl_version = @ssl_version if @ssl_version # deprecated; prefer min/max_version
        conn.cert = @cert if @cert
        conn.key = @key if @key
      end

      conn.set_debug_output(@logger) if @logger
      conn
    end
  end
end
