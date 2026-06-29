require "net_http_hacked"
require "rack/http_streaming_response"

module Rack

  # Subclass and bring your own #rewrite_request and #rewrite_response
  class Proxy
    VERSION = "0.8.3".freeze

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

    class << self
      def extract_http_request_headers(env)
        headers = env.reject do |k, v|
          !(/^HTTP_[A-Z0-9_\.]+$/ === k) || v.nil?
        end.map do |k, v|
          [reconstruct_header_name(k), v]
        end.then { |pairs| build_header_hash(pairs) }

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

    protected

    def perform_request(env)
      source_request = Rack::Request.new(env)

      # Initialize request
      if source_request.fullpath == ""
        full_path = URI.parse(env['REQUEST_URI']).request_uri
      else
        full_path = source_request.fullpath
      end

      target_request = Net::HTTP.const_get(source_request.request_method.capitalize, false).new(full_path)

      # Setup headers
      target_request.initialize_http_header(self.class.extract_http_request_headers(source_request.env))

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
      use_ssl = backend.scheme == "https" || @cert
      read_timeout = env.delete('http.read_timeout') || @read_timeout

      # Create the response
      begin
        if @streaming
          # streaming response (the actual network communication is deferred, a.k.a. streamed)
          target_response = HttpStreamingResponse.new(target_request, backend.host, backend.port)
          target_response.use_ssl = use_ssl
          target_response.read_timeout = read_timeout
          target_response.ssl_version = @ssl_version if @ssl_version
          target_response.verify_mode = (@verify_mode || OpenSSL::SSL::VERIFY_PEER) if use_ssl
          target_response.cert = @cert if @cert
          target_response.key = @key if @key
          target_response.logger = @logger if @logger
        else
          http = Net::HTTP.new(backend.host, backend.port)
          http.use_ssl = use_ssl if use_ssl
          http.read_timeout = read_timeout
          http.ssl_version = @ssl_version if @ssl_version
          http.verify_mode = @verify_mode || OpenSSL::SSL::VERIFY_PEER if use_ssl
          http.cert = @cert if @cert
          http.key = @key if @key
          http.set_debug_output(@logger) if @logger

          target_response = http.start do
            http.request(target_request)
          end
        end

        code    = target_response.code
        headers = self.class.normalize_headers(target_response.respond_to?(:headers) ? target_response.headers : target_response.to_hash)
        body    = target_response.body || []
        body    = [body] unless body.respond_to?(:each)
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT, Net::OpenTimeout, SocketError
        return [502, {}, []]
      end

      # No entity body for status codes that don't allow one (1xx, 204, 304)
      body = [] if Rack::Utils::STATUS_WITH_NO_ENTITY_BODY[code.to_i]

      # According to https://tools.ietf.org/html/draft-ietf-httpbis-p1-messaging-14#section-7.1.3.1Acc
      # should remove hop-by-hop header fields
      headers.reject! { |k| HOP_BY_HOP_HEADERS[k.downcase] }

      [code, headers, body]
    end
  end
end
