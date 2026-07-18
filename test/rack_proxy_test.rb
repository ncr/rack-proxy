require "test_helper"
require "rack/proxy"

class RackProxyTest < Test::Unit::TestCase
  class HostProxy < Rack::Proxy
    attr_accessor :host

    def rewrite_env(env)
      env["HTTP_HOST"] = host || "example.com"
      env
    end
  end

  # HostProxy routes by rewriting the Host header (dynamic mode), which is
  # refused by default since 1.0 — the helpers opt in so the suite can exercise
  # the network paths. The refusal default has its own guards below.
  def app(opts = {})
    @app ||= HostProxy.new({allow_dynamic_backend: true}.merge(opts))
  end

  def test_http_streaming
    with_webrick_proxy do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/"
      assert last_response.ok?
      assert_match(/Example Domain/, last_response.body)
    end
  end

  def test_http_full_request
    with_webrick_proxy(streaming: false) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/"
      assert last_response.ok?
      assert_match(/Example Domain/, last_response.body)
    end
  end

  def test_http_full_request_headers
    with_webrick_proxy(streaming: false) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/cookies/set?test=1"
      assert !Array(last_response["Set-Cookie"]).empty?, "/cookies/set should set a cookie"
    end
  end

  # The offline HTTPS tests proxy over TLS to a self-signed local server with
  # verification disabled, exercising the streaming/non-streaming TLS transport
  # and the :ssl_version plumbing. The VERIFY_PEER *success* path is covered
  # hermetically by test_https_ca_file_accepts_trusted_cert_* below (via
  # :ca_file); test/live_smoke_test.rb only adds system-trust-store coverage.
  def test_https_streaming
    with_webrick_proxy(ssl: true, ssl_verify_none: true) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "https://example.com"
      assert last_response.ok?
      assert_match(/Example Domain/, last_response.body)
    end
  end

  # Uses the modern :min_version option (:ssl_version is deprecated). The other
  # _tls test below still exercises :ssl_version for backward compatibility.
  def test_https_streaming_tls
    with_webrick_proxy(ssl: true, ssl_verify_none: true, min_version: :TLS1_2) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "https://example.com"
      assert last_response.ok?
      assert_match(/Example Domain/, last_response.body)
    end
  end

  def test_https_full_request
    with_webrick_proxy(ssl: true, streaming: false, ssl_verify_none: true) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "https://example.com"
      assert last_response.ok?
      assert_match(/Example Domain/, last_response.body)
    end
  end

  def test_https_full_request_tls
    with_webrick_proxy(ssl: true, streaming: false, ssl_verify_none: true, ssl_version: :TLSv1_2) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "https://example.com"
      assert last_response.ok?
      assert_match(/Example Domain/, last_response.body)
    end
  end

  def test_normalize_headers
    proxy_class = Rack::Proxy
    headers = {"header_array" => ["first_entry"], "header_non_array" => :entry}

    normalized_headers = proxy_class.send(:normalize_headers, headers)
    expected_class = Rack.const_defined?(:Headers) ? Rack::Headers : Rack::Utils::HeaderHash
    assert normalized_headers.instance_of?(expected_class)
    assert normalized_headers["header_array"] == "first_entry"
    assert normalized_headers["header_non_array"] == :entry
  end

  def test_header_reconstruction
    proxy_class = Rack::Proxy

    header = proxy_class.send(:reconstruct_header_name, "HTTP_ABC")
    assert header == "Abc"

    header = proxy_class.send(:reconstruct_header_name, "HTTP_ABC_D")
    assert header == "Abc-D"
  end

  def test_extract_http_request_headers
    proxy_class = Rack::Proxy
    env = {
      "NOT-HTTP-HEADER" => "test-value",
      "HTTP_ACCEPT" => "text/html",
      "HTTP_CONNECTION" => nil,
      "HTTP_CONTENT_MD5" => "deadbeef",
      "HTTP_HEADER.WITH.PERIODS" => "stillmooing"
    }

    headers = proxy_class.extract_http_request_headers(env)
    assert headers.key?("ACCEPT")
    assert headers.key?("CONTENT-MD5")
    assert headers.key?("HEADER.WITH.PERIODS")
    assert !headers.key?("CONNECTION")
    assert !headers.key?("NOT-HTTP-HEADER")
  end

  def test_duplicate_headers
    proxy_class = Rack::Proxy
    env = {"Set-Cookie" => ["cookie1=foo", "cookie2=bar"]}

    headers = proxy_class.normalize_headers(env)
    assert headers["Set-Cookie"].include?("cookie1=foo"), "Include the first value"
    assert headers["Set-Cookie"].include?("\n"), "Join multiple cookies with newlines"
    assert headers["Set-Cookie"].include?("cookie2=bar"), "Include the second value"
  end

  def test_handles_missing_content_length
    assert_nothing_thrown do
      post "/", nil, "CONTENT_LENGTH" => nil
    end
  end

  # An input stream that deliberately omits #rewind, mimicking
  # Rackup::Handler::WEBrick::Input under Rack 3 (the Rack 3 SPEC no longer
  # requires the input stream to respond to #rewind, only gets/each/read).
  class NonRewindableInput
    def initialize(string)
      @io = StringIO.new(string)
    end

    def read(*args) = @io.read(*args)
    def gets(*args) = @io.gets(*args)
    def each(&block) = @io.each(&block)
    # intentionally NO #rewind
  end

  # Issue #128: a non-rewindable body stream must not raise (it used to blow up
  # with NoMethodError on #rewind, surfacing confusingly as a 500). The body
  # must still be forwarded intact, since it is never read before Net::HTTP sends it.
  def test_non_rewindable_body_is_forwarded_without_raising
    with_webrick_proxy(streaming: false) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"

      body = NonRewindableInput.new("hello=world")
      assert !body.respond_to?(:rewind), "fixture must not be rewindable to exercise the guard"

      env = Rack::MockRequest.env_for("/echo-body", method: "POST")
      env["rack.input"] = body
      env["CONTENT_LENGTH"] = "hello=world".bytesize.to_s
      env["CONTENT_TYPE"] = "text/plain"

      status, _headers, response = nil
      assert_nothing_raised { status, _headers, response = proxy.call(env) }
      assert_equal 200, status.to_i
      assert_equal "hello=world", response.to_a.join, "body must be forwarded intact"
    end
  end

  # Issue: hop-by-hop headers (here Transfer-Encoding, sent by the chunked
  # backend) must be stripped from the response. The local /chunked route makes
  # this assertion meaningful — the previous live-host version passed vacuously
  # because the backend never actually sent a hop-by-hop header.
  def test_response_header_included_Hop_by_hop
    with_webrick_proxy(streaming: true) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/chunked"
      # Assert on the headers actually emitted to the client (iteration), not
      # via #key?: Rack 2's HeaderHash#reject! leaves a stale case-insensitive
      # index, so #key? can report a header that iteration correctly omits.
      transfer_encoding_emitted =
        last_response.headers.any? { |k, _| k.downcase == "transfer-encoding" }
      assert !transfer_encoding_emitted,
        "hop-by-hop Transfer-Encoding must be stripped from the proxied response"
      assert_match(/chunk-one/, last_response.body, "chunked body must still be forwarded")
    end
  end

  # Issue #58: connection errors should return 502, not raise.
  def test_connection_refused_returns_502
    # Bind a socket to find a free port, then close it so connection is refused.
    server = TCPServer.new("127.0.0.1", 0)
    closed_port = server.addr[1]
    server.close

    app({streaming: false}).host = "127.0.0.1:#{closed_port}"
    get "/"
    assert_equal 502, last_response.status
    assert_equal "", last_response.body
  end

  def test_connection_refused_returns_502_streaming
    server = TCPServer.new("127.0.0.1", 0)
    closed_port = server.addr[1]
    server.close

    app({streaming: true}).host = "127.0.0.1:#{closed_port}"
    get "/"
    assert_equal 502, last_response.status
    assert_equal "", last_response.body
  end

  # `.invalid` is reserved (RFC 6761) and never resolves, so this stays
  # deterministic and offline: the SocketError from a failed DNS lookup must be
  # mapped to 502, not raised.
  def test_unknown_host_returns_502
    app({streaming: false}).host = "no-such-host.invalid"
    get "/"
    assert_equal 502, last_response.status
  end

  # Issues #122/#123: body should be [] for empty responses and for status
  # codes that don't allow an entity body (1xx, 204, 304).
  def test_no_entity_body_for_204
    with_webrick_proxy(streaming: false) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/no-content"
      assert_equal 204, last_response.status
      assert_equal "", last_response.body
    end
  end

  def test_no_entity_body_for_304
    with_webrick_proxy(streaming: false) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/not-modified"
      assert_equal 304, last_response.status
      assert_equal "", last_response.body
    end
  end

  # Same guards on the default (streaming) path: the streaming body must close
  # the backend connection for these statuses without emitting an entity body
  # (P1-5 exercises this through the Fiber-based streamer).
  def test_no_entity_body_for_204_streaming
    with_webrick_proxy(streaming: true) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/no-content"
      assert_equal 204, last_response.status
      assert_equal "", last_response.body
    end
  end

  def test_no_entity_body_for_304_streaming
    with_webrick_proxy(streaming: true) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/not-modified"
      assert_equal 304, last_response.status
      assert_equal "", last_response.body
    end
  end

  def test_head_request_streaming
    with_webrick_proxy(streaming: true) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      head "/"
      assert last_response.ok?
      assert_equal "", last_response.body, "HEAD must not stream an entity body"
    end
  end

  # P3-1: opt-in hardening. :strip_credentials must drop Cookie/Authorization
  # from the forwarded request; without it both forward verbatim (standard
  # proxy behavior, guarded here so neither direction regresses silently).
  def test_strip_credentials_removes_cookie_and_authorization
    with_webrick_proxy(strip_credentials: true) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/echo-request-headers", {},
        "HTTP_COOKIE" => "session=s3cr3t", "HTTP_AUTHORIZATION" => "Bearer tok"
      assert last_response.ok?
      assert_not_match(/^cookie:/, last_response.body, "Cookie must be stripped")
      assert_not_match(/^authorization:/, last_response.body, "Authorization must be stripped")
    end
  end

  def test_credentials_forwarded_by_default
    with_webrick_proxy do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/echo-request-headers", {},
        "HTTP_COOKIE" => "session=s3cr3t", "HTTP_AUTHORIZATION" => "Bearer tok"
      assert_match(/^cookie: session=s3cr3t$/, last_response.body)
      assert_match(/^authorization: Bearer tok$/, last_response.body)
    end
  end

  # P3-1: :replace_x_forwarded_for must hide the client-supplied chain and
  # forward only this hop's REMOTE_ADDR; the default appends to the chain.
  def test_replace_x_forwarded_for_hides_inbound_chain
    with_webrick_proxy(replace_x_forwarded_for: true) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/echo-request-headers", {},
        "HTTP_X_FORWARDED_FOR" => "203.0.113.9", "REMOTE_ADDR" => "10.0.0.5"
      assert_match(/^x-forwarded-for: 10\.0\.0\.5$/, last_response.body,
        "inbound X-Forwarded-For must be replaced with REMOTE_ADDR")
    end
  end

  def test_x_forwarded_for_appends_by_default
    with_webrick_proxy do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/echo-request-headers", {},
        "HTTP_X_FORWARDED_FOR" => "203.0.113.9", "REMOTE_ADDR" => "10.0.0.5"
      assert_match(/^x-forwarded-for: 203\.0\.113\.9, 10\.0\.0\.5$/, last_response.body)
    end
  end

  # Pins the documented ordering: the strip runs on the extracted headers
  # AFTER rewrite_env, so an Authorization injected there is stripped too —
  # while the :username/:password credential survives (applied to the outgoing
  # request after the strip). Proxy-owned credentials belong in those options.
  def test_strip_credentials_applies_after_rewrite_env
    with_webrick_proxy(strip_credentials: true, username: "u", password: "p") do |port, proxy|
      def proxy.rewrite_env(env)
        env["HTTP_AUTHORIZATION"] = "Bearer injected-by-rewrite-env"
        super
      end
      proxy.host = "127.0.0.1:#{port}"
      get "/echo-request-headers"
      assert last_response.ok?
      assert_not_match(/injected-by-rewrite-env/, last_response.body,
        "a credential injected in rewrite_env is stripped like any other")
      assert_match(/^authorization: Basic dTpw$/, last_response.body,
        ":username/:password must survive strip_credentials")
    end
  end

  # The REMOTE_ADDR-less arm of :replace_x_forwarded_for: with no peer address
  # to substitute, the header must be dropped entirely, not sent empty.
  def test_replace_x_forwarded_for_without_remote_addr_drops_header
    with_webrick_proxy(replace_x_forwarded_for: true) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      env = Rack::MockRequest.env_for("/echo-request-headers")
      env["HTTP_X_FORWARDED_FOR"] = "203.0.113.9"
      env.delete("REMOTE_ADDR")
      _status, _headers, body = proxy.call(env)
      assert_not_match(/x-forwarded-for/, body.to_s,
        "with no REMOTE_ADDR, X-Forwarded-For must be dropped, not forwarded or sent empty")
    end
  end

  # A request body must round-trip through the default (streaming) path too —
  # the non-streaming POST coverage alone would let a fiber-path body bug slip.
  def test_post_body_is_forwarded_streaming
    with_webrick_proxy(streaming: true) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      post "/echo-body", "hello=streaming-world"
      assert last_response.ok?
      assert_equal "hello=streaming-world", last_response.body
    end
  end

  # A backend replying with a malformed status line must become a 502, not a
  # raised Net::HTTPBadResponse (which subclasses StandardError directly, NOT
  # Net::ProtocolError — easy to get wrong in BACKEND_ERRORS).
  def test_malformed_backend_response_returns_502
    [true, false].each do |streaming|
      with_malformed_backend do |port|
        proxy = HostProxy.new(streaming: streaming, allow_dynamic_backend: true)
        @app = proxy
        proxy.host = "127.0.0.1:#{port}"
        get "/"
        assert_equal 502, last_response.status,
          "malformed backend response must 502 (streaming: #{streaming})"
      ensure
        @app = nil
      end
    end
  end

  def test_empty_body_is_not_array_with_empty_string
    with_webrick_proxy(streaming: false) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/empty"
      assert_equal 200, last_response.status
      assert_equal "", last_response.body
    end
  end

  # Issue #65: header values must be strings, not single-element arrays,
  # for both streaming and non-streaming paths.
  def test_header_values_are_strings_streaming
    assert_no_array_header_values(streaming: true)
  end

  def test_header_values_are_strings_non_streaming
    assert_no_array_header_values(streaming: false)
  end

  # Issue #113: SSL cert verification must default to VERIFY_PEER (Ruby's
  # Net::HTTP default), not VERIFY_NONE. INVARIANT — see CLAUDE.md.
  def test_ssl_default_is_verify_peer
    proxy = Rack::Proxy.new
    assert_nil proxy.instance_variable_get(:@verify_mode),
      "@verify_mode should be unset by default so VERIFY_PEER applies at request time"
  end

  def test_ssl_verify_none_opt_in
    proxy = Rack::Proxy.new(ssl_verify_none: true)
    assert_equal OpenSSL::SSL::VERIFY_NONE, proxy.instance_variable_get(:@verify_mode)
  end

  def test_explicit_verify_mode_wins_over_ssl_verify_none
    proxy = Rack::Proxy.new(ssl_verify_none: true, verify_mode: OpenSSL::SSL::VERIFY_PEER)
    assert_equal OpenSSL::SSL::VERIFY_PEER, proxy.instance_variable_get(:@verify_mode)
  end

  # The local HTTPS server uses a self-signed cert, so the default VERIFY_PEER
  # must reject it. This is the hermetic replacement for the old badssl.com test
  # and is now the primary regression guard for the VERIFY_PEER default. Since
  # Batch 2 maps backend failures to 502 (rather than raising), we assert 502 and
  # use the logger to confirm the cause is specifically a TLS verification error.
  def test_https_default_rejects_invalid_certificate
    sink = StringIO.new
    with_webrick_proxy(ssl: true, streaming: false, logger: sink) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "https://example.com/"
      assert_equal 502, last_response.status,
        "a backend cert failing VERIFY_PEER must become 502, not a raised 500"
      assert_match(/SSLError|certificate verify failed/, sink.string,
        "expected the 502 to be caused by a TLS verification failure, got: #{sink.string.inspect}")
    end
  end

  # Same guard for the default (streaming) path, which previously had no
  # VERIFY_PEER coverage at all (P1-4 deduped the TLS config into one place).
  def test_https_default_rejects_invalid_certificate_streaming
    sink = StringIO.new
    with_webrick_proxy(ssl: true, streaming: true, logger: sink) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "https://example.com/"
      assert_equal 502, last_response.status
      assert_match(/SSLError|certificate verify failed/, sink.string)
    end
  end

  def test_https_with_ssl_verify_none_accepts_invalid_certificate
    with_webrick_proxy(ssl: true, streaming: false, ssl_verify_none: true) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "https://example.com/"
      assert last_response.ok?
    end
  end

  # P1-6: with a :ca_file that trusts the backend's CA, the default VERIFY_PEER
  # must *accept* the (otherwise-untrusted) cert. This is the keystone hermetic
  # VERIFY_PEER-success test that previously required a live host.
  def test_https_ca_file_accepts_trusted_cert_non_streaming
    with_webrick_proxy(ssl: true, ca_signed: true, streaming: false, ca_file: ProxyTestServer.ca_file) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "https://example.com/"
      assert last_response.ok?, "VERIFY_PEER must accept a cert signed by the configured ca_file"
      assert_match(/Example Domain/, last_response.body)
    end
  end

  def test_https_ca_file_accepts_trusted_cert_streaming
    with_webrick_proxy(ssl: true, ca_signed: true, streaming: true, ca_file: ProxyTestServer.ca_file) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "https://example.com/"
      assert last_response.ok?
      assert_match(/Example Domain/, last_response.body)
    end
  end

  # Without the ca_file, the same CA-signed cert is untrusted and must be rejected
  # (-> 502), proving the ca_file is what establishes trust.
  def test_https_ca_signed_cert_rejected_without_ca_file
    with_webrick_proxy(ssl: true, ca_signed: true, streaming: false) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "https://example.com/"
      assert_equal 502, last_response.status
    end
  end

  # P2-2: :open_timeout / :write_timeout must be wired onto the connection
  # (Net::HTTP defaults them to 60s, unreachable via :read_timeout alone).
  def test_connect_and_write_timeouts_are_applied
    proxy = Rack::Proxy.new(read_timeout: 5, open_timeout: 3, write_timeout: 7)
    http = Net::HTTP.new("127.0.0.1", 80)
    proxy.send(:configure_backend_connection, http, use_ssl: false, read_timeout: 5)
    assert_equal 5, http.read_timeout
    assert_equal 3, http.open_timeout
    assert_equal 7, http.write_timeout
  end

  # P1-6: :ca_file / :cert_store must be wired onto the TLS connection.
  def test_ca_file_and_cert_store_are_applied
    store = OpenSSL::X509::Store.new
    proxy = Rack::Proxy.new(ca_file: "/tmp/some-ca.pem", cert_store: store)
    http = Net::HTTP.new("127.0.0.1", 443)
    proxy.send(:configure_backend_connection, http, use_ssl: true, read_timeout: 5)
    assert_equal "/tmp/some-ca.pem", http.ca_file
    assert_same store, http.cert_store
  end

  # Issue #80: a :logger option should pipe Net::HTTP debug output to the
  # given sink (anything responding to #<<). We use a StringIO to capture it.
  def test_logger_captures_request_in_non_streaming
    sink = StringIO.new
    with_webrick_proxy(streaming: false, logger: sink) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/empty"
      assert last_response.ok?
    end
    assert_match(/GET \/empty/, sink.string,
      "expected debug output to include request line, got: #{sink.string.inspect}")
  end

  def test_logger_captures_request_in_streaming
    sink = StringIO.new
    with_webrick_proxy(streaming: true, logger: sink) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/empty"
      assert last_response.ok?
    end
    assert_match(/GET \/empty/, sink.string,
      "expected debug output to include request line, got: #{sink.string.inspect}")
  end

  # Regression: build_header_hash must not match a top-level ::Headers
  # constant defined by the host app (would happen with inherit: true).
  def test_build_header_hash_ignores_toplevel_headers_constant
    Object.send(:remove_const, :Headers) if Object.const_defined?(:Headers, false)
    Object.const_set(:Headers, Class.new)
    begin
      result = Rack::Proxy.send(:build_header_hash, [["X-Test", "value"]])
      # On Rack 3+ we get Rack::Headers; on Rack 2 we get Rack::Utils::HeaderHash.
      # In neither case should we get the bogus top-level ::Headers.
      assert_not_equal ::Headers, result.class,
        "build_header_hash leaked into top-level ::Headers"
    ensure
      Object.send(:remove_const, :Headers)
    end
  end

  def test_no_logger_means_no_debug_output
    # Without a :logger option, Net::HTTP's set_debug_output should never be
    # called. We can't directly assert that, but we can confirm requests still
    # work when no logger is configured (covered by every other test).
    with_webrick_proxy(streaming: false) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/empty"
      assert last_response.ok?
    end
  end

  # P0-2: hop-by-hop headers (and any header named by Connection) must be
  # stripped from the FORWARDED REQUEST, closing the CL/TE smuggling surface.
  def test_request_hop_by_hop_headers_are_stripped
    env = {
      "REMOTE_ADDR" => "10.0.0.1",
      "HTTP_ACCEPT" => "text/html",
      "HTTP_CONNECTION" => "keep-alive, X-Purge-Me",
      "HTTP_KEEP_ALIVE" => "timeout=5",
      "HTTP_TE" => "trailers",
      "HTTP_TRANSFER_ENCODING" => "chunked",
      "HTTP_PROXY_AUTHORIZATION" => "Basic zzz",
      "HTTP_UPGRADE" => "websocket",
      "HTTP_X_PURGE_ME" => "please",
      "HTTP_AUTHORIZATION" => "Bearer keep-me"
    }
    headers = Rack::Proxy.extract_http_request_headers(env)

    %w[Connection Keep-Alive Te Transfer-Encoding Proxy-Authorization Upgrade].each do |h|
      assert !headers.key?(h), "#{h} is hop-by-hop and must not be forwarded"
    end
    assert !headers.key?("X-Purge-Me"), "a header named in Connection must be dropped"
    assert_equal "text/html", headers["Accept"], "end-to-end headers must survive"
    assert_equal "Bearer keep-me", headers["Authorization"], "end-to-end Authorization must survive"
  end

  # P0-6: a gzip-encoded backend body must be forwarded verbatim (still
  # compressed, Content-Encoding intact, Content-Length matching the bytes sent),
  # not transparently inflated (which desyncs Content-Length).
  def test_gzip_body_is_forwarded_verbatim_non_streaming
    assert_gzip_forwarded_verbatim(streaming: false)
  end

  def test_gzip_body_is_forwarded_verbatim_streaming
    assert_gzip_forwarded_verbatim(streaming: true)
  end

  # P0-3: a method with no Net::HTTP::<Verb> class must be 501, not a raised 500.
  # (Net::HTTP does define WebDAV verbs like PROPFIND, so use a truly unknown one.)
  def test_unknown_method_returns_501
    with_webrick_proxy(streaming: false) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      env = Rack::MockRequest.env_for("/", method: "GET")
      env["REQUEST_METHOD"] = "BOGUSVERB"
      status, _headers, _body = proxy.call(env)
      assert_equal 501, status
    end
  end

  # P0-4: a backend refused by backend_allowed? must 502 even when the backend
  # is reachable and would otherwise succeed.
  def test_disallowed_backend_returns_502
    with_webrick_proxy(streaming: false) do |port, proxy|
      def proxy.backend_allowed?(_backend)
        false
      end
      proxy.host = "127.0.0.1:#{port}"
      get "/"
      assert_equal 502, last_response.status
    end
  end

  # 1.0 BREAKING / SSRF guard: with no :backend and no opt-in, a Host-derived
  # destination must be refused with 502 — even when it would be reachable —
  # and the refusal must be dialed nowhere (the backend sees no request).
  def test_dynamic_backend_refused_by_default
    server, port = ProxyTestServer.start_server
    hits = 0
    server.mount_proc("/hit-counter") do |_req, res|
      hits += 1
      res.body = "hit"
    end

    sink = StringIO.new
    proxy = HostProxy.new(logger: sink) # deliberately NOT allow_dynamic_backend
    @app = proxy
    proxy.host = "127.0.0.1:#{port}"
    get "/hit-counter"

    assert_equal 502, last_response.status
    assert_equal 0, hits, "a refused dynamic backend must never be dialed"
    assert_match(/allow_dynamic_backend/, sink.string,
      "the refusal should log a migration hint")
  ensure
    server&.shutdown
    @app = nil
  end

  # A configured :backend is app-controlled and needs no opt-in.
  def test_static_backend_requires_no_opt_in
    server, port = ProxyTestServer.start_server
    proxy = Rack::Proxy.new(backend: "http://127.0.0.1:#{port}")
    status, _headers, body = proxy.call(Rack::MockRequest.env_for("/"))
    assert_equal 200, status.to_i
    assert_match(/Example Domain/, body.to_s)
  ensure
    server&.shutdown
  end

  # env["rack.backend"] is set by the app's own rewrite_env — also trusted.
  def test_rack_backend_env_requires_no_opt_in
    server, port = ProxyTestServer.start_server
    proxy = Rack::Proxy.new
    env = Rack::MockRequest.env_for("/")
    env["rack.backend"] = URI("http://127.0.0.1:#{port}")
    status, _headers, body = proxy.call(env)
    assert_equal 200, status.to_i
    assert_match(/Example Domain/, body.to_s)
  ensure
    server&.shutdown
  end

  # backend_allowed? must be consulted for static backends too, not just
  # dynamic ones — it is the fine-grained allowlist on top of the mode gate.
  def test_backend_allowed_consulted_for_static_backend
    server, port = ProxyTestServer.start_server
    proxy = Rack::Proxy.new(backend: "http://127.0.0.1:#{port}")
    def proxy.backend_allowed?(_backend) = false
    status, _headers, _body = proxy.call(Rack::MockRequest.env_for("/"))
    assert_equal 502, status
  ensure
    server&.shutdown
  end

  # The library must load standalone, print nothing, and must NOT define the
  # old net_http_hacked monkey-patch (deleted in 1.0) — guards reintroduction.
  # Runs in a subprocess so this file's own requires can't mask a regression.
  def test_library_loads_cleanly_without_the_old_monkey_patch
    lib = File.expand_path("../lib", __dir__)
    out = IO.popen(
      [RbConfig.ruby, "-I", lib, "-e",
        'require "rack/proxy"; print Net::HTTP.method_defined?(:begin_request_hacked) ? "PATCHED" : "CLEAN"'],
      err: [:child, :out], &:read
    )
    assert_equal "CLEAN", out,
      "requiring rack/proxy must define no hacked methods and print nothing; got: #{out.inspect}"
  end

  # P0-5: an interim 103 Early Hints from the backend must be skipped so the
  # final 200 (and its body) is returned, on the default streaming path.
  def test_early_hints_103_is_skipped_streaming
    with_early_hints_backend do |port|
      proxy = HostProxy.new(streaming: true, allow_dynamic_backend: true)
      @app = proxy
      proxy.host = "127.0.0.1:#{port}"
      get "/"
      assert_equal 200, last_response.status.to_i, "must return the final 200, not the interim 103"
      assert_equal "hello world", last_response.body
    end
  ensure
    @app = nil
  end

  # P2-3: :max_response_length caps the backend response size.
  def test_max_response_length_rejects_declared_oversize_non_streaming
    with_webrick_proxy(streaming: false, max_response_length: 10) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/" # body is well over 10 bytes, with a Content-Length
      assert_equal 502, last_response.status
    end
  end

  def test_max_response_length_rejects_declared_oversize_streaming
    with_webrick_proxy(streaming: true, max_response_length: 10) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/"
      assert_equal 502, last_response.status
    end
  end

  # No Content-Length (chunked): the cap must still fire incrementally while
  # streaming, aborting the transfer with ResponseTooLarge.
  def test_max_response_length_enforced_while_streaming_chunked
    with_webrick_proxy(streaming: true, max_response_length: 5) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      status, _headers, body = proxy.call(Rack::MockRequest.env_for("/chunked"))
      assert_equal 200, status.to_i, "headers precede the body, so status is still 200"
      assert_raise(Rack::HttpStreamingResponse::ResponseTooLarge) { body.each { |_chunk| } }
    end
  end

  def test_max_response_length_allows_within_limit
    with_webrick_proxy(streaming: false, max_response_length: 100_000) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/"
      assert last_response.ok?
      assert_match(/Example Domain/, last_response.body)
    end
  end

  private

  def assert_gzip_forwarded_verbatim(streaming:)
    with_webrick_proxy(streaming: streaming) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/gzip"
      assert last_response.ok?
      body = last_response.body
      assert_equal "gzip", last_response["content-encoding"], "Content-Encoding must be preserved"
      inflated = Zlib::GzipReader.new(StringIO.new(body.b)).read
      assert_equal ProxyTestServer::GZIP_PLAINTEXT.b, inflated.b,
        "body must still be compressed and round-trip to the original payload"
      if (content_length = last_response["content-length"])
        assert_equal body.bytesize, content_length.to_i,
          "Content-Length must match the (compressed) bytes actually forwarded"
      end
    end
  end

  # A raw TCP backend that replies with a malformed status line (a hostile or
  # broken backend), to prove the parse failure maps to 502 instead of raising.
  def with_malformed_backend
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      client = server.accept
      client.gets("\r\n\r\n") # consume request headers
      client.write("garbage nonsense\r\n\r\n")
      client.close
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      # client went away; nothing to do
    ensure
      server.close
    end
    yield port
  ensure
    thread&.join(2)
  end

  # A raw TCP backend that emits a 103 Early Hints interim response followed by a
  # final 200. WEBrick can't send 1xx interim responses, so we speak HTTP by hand.
  def with_early_hints_backend
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      client = server.accept
      client.gets("\r\n\r\n") # consume request headers
      client.write("HTTP/1.1 103 Early Hints\r\nLink: </s.css>; rel=preload\r\n\r\n")
      client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello world")
      client.close
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      # client went away; nothing to do
    ensure
      server.close
    end
    yield port
  ensure
    thread&.join(2)
  end

  def assert_no_array_header_values(streaming:)
    with_webrick_proxy(streaming: streaming) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get "/echo-headers"
      array_valued = last_response.headers.select { |_, v| v.is_a?(Array) }
      assert_empty array_valued,
        "expected no Array-valued headers (#65), got: #{array_valued.inspect}"
      assert_equal "value-here", last_response["x-custom"]
    end
  end

  # Spin up a tiny local WEBrick server (see test/support/proxy_test_server.rb)
  # so we can exercise the proxy against real Net::HTTP requests without touching
  # the network. Pass ssl: true for an HTTPS backend with a self-signed cert; all
  # other keyword options are forwarded to the proxy (e.g. streaming:,
  # ssl_verify_none:, ssl_version:, logger:).
  def with_webrick_proxy(ssl: false, ca_signed: false, **proxy_opts)
    server, port = ProxyTestServer.start_server(ssl: ssl, ca_signed: ca_signed)

    proxy = HostProxy.new(allow_dynamic_backend: true, **proxy_opts)
    @app = proxy
    yield port, proxy
  ensure
    server&.shutdown
    @app = nil
  end
end
