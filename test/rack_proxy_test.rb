require "test_helper"
require "rack/proxy"

class RackProxyTest < Test::Unit::TestCase
  class HostProxy < Rack::Proxy
    attr_accessor :host

    def rewrite_env(env)
      env["HTTP_HOST"] = self.host || 'example.com'
      env
    end
  end

  def app(opts = {})
    return @app ||= HostProxy.new(opts)
  end

  def test_http_streaming
    get "/"
    assert last_response.ok?

    assert_match(/Example Domain/, last_response.body)
  end

  def test_http_full_request
    app(:streaming => false)
    get "/"
    assert last_response.ok?
    assert_match(/Example Domain/, last_response.body)
  end

  def test_http_full_request_headers
    app(:streaming => false)
    app.host = 'httpbin.org'
    get "/cookies/set?test=1"
    assert !Array(last_response['Set-Cookie']).empty?, 'httpbin.org/cookies/set should set a cookie'
  end

  def test_https_streaming
    app.host = 'www.apple.com'
    get 'https://example.com'
    assert last_response.ok?
    assert_match(/(itunes|iphone|ipod|mac|ipad)/, last_response.body)
  end

  def test_https_streaming_tls
    app(:ssl_version => :TLSv1_2).host = 'www.apple.com'
    get 'https://example.com'
    assert last_response.ok?
    assert_match(/(itunes|iphone|ipod|mac|ipad)/, last_response.body)
  end

  def test_https_full_request
    app(:streaming => false).host = 'www.apple.com'
    get 'https://example.com'
    assert last_response.ok?
    assert_match(/(itunes|iphone|ipod|mac|ipad)/, last_response.body)
  end

  def test_https_full_request_tls
    app({:streaming => false, :ssl_version => :TLSv1_2}).host = 'www.apple.com'
    get 'https://example.com'
    assert last_response.ok?
    assert_match(/(itunes|iphone|ipod|mac|ipad)/, last_response.body)
  end

  def test_normalize_headers
    proxy_class = Rack::Proxy
    headers = { 'header_array' => ['first_entry'], 'header_non_array' => :entry }

    normalized_headers = proxy_class.send(:normalize_headers, headers)
    expected_class = Rack.const_defined?(:Headers) ? Rack::Headers : Rack::Utils::HeaderHash
    assert normalized_headers.instance_of?(expected_class)
    assert normalized_headers['header_array'] == 'first_entry'
    assert normalized_headers['header_non_array'] == :entry
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
      'NOT-HTTP-HEADER' => 'test-value',
      'HTTP_ACCEPT' => 'text/html',
      'HTTP_CONNECTION' => nil,
      'HTTP_CONTENT_MD5' => 'deadbeef',
      'HTTP_HEADER.WITH.PERIODS' => 'stillmooing'
    }

    headers = proxy_class.extract_http_request_headers(env)
    assert headers.key?('ACCEPT')
    assert headers.key?('CONTENT-MD5')
    assert headers.key?('HEADER.WITH.PERIODS')
    assert !headers.key?('CONNECTION')
    assert !headers.key?('NOT-HTTP-HEADER')
  end

  def test_duplicate_headers
    proxy_class = Rack::Proxy
    env = { 'Set-Cookie' => ["cookie1=foo", "cookie2=bar"] }

    headers = proxy_class.normalize_headers(env)
    assert headers['Set-Cookie'].include?('cookie1=foo'), "Include the first value"
    assert headers['Set-Cookie'].include?("\n"), "Join multiple cookies with newlines"
    assert headers['Set-Cookie'].include?('cookie2=bar'), "Include the second value"
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
      env["rack.input"]     = body
      env["CONTENT_LENGTH"] = "hello=world".bytesize.to_s
      env["CONTENT_TYPE"]   = "text/plain"

      status, _headers, response = nil
      assert_nothing_raised { status, _headers, response = proxy.call(env) }
      assert_equal 200, status.to_i
      assert_equal "hello=world", response.to_a.join, "body must be forwarded intact"
    end
  end

  def test_response_header_included_Hop_by_hop
    app({:streaming => true}).host = 'mockapi.io'
    get 'https://example.com/oauth2/token/info?access_token=123'
    assert !last_response.headers.key?('transfer-encoding')
  end

  # Issue #58: connection errors should return 502, not raise.
  def test_connection_refused_returns_502
    # Bind a socket to find a free port, then close it so connection is refused.
    server = TCPServer.new('127.0.0.1', 0)
    closed_port = server.addr[1]
    server.close

    app({:streaming => false}).host = "127.0.0.1:#{closed_port}"
    get '/'
    assert_equal 502, last_response.status
    assert_equal '', last_response.body
  end

  def test_connection_refused_returns_502_streaming
    server = TCPServer.new('127.0.0.1', 0)
    closed_port = server.addr[1]
    server.close

    app({:streaming => true}).host = "127.0.0.1:#{closed_port}"
    get '/'
    assert_equal 502, last_response.status
    assert_equal '', last_response.body
  end

  def test_unknown_host_returns_502
    app({:streaming => false}).host = 'no-such-host.invalid'
    get '/'
    assert_equal 502, last_response.status
  end

  # Issues #122/#123: body should be [] for empty responses and for status
  # codes that don't allow an entity body (1xx, 204, 304).
  def test_no_entity_body_for_204
    with_webrick_proxy(streaming: false) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get '/no-content'
      assert_equal 204, last_response.status
      assert_equal '', last_response.body
    end
  end

  def test_no_entity_body_for_304
    with_webrick_proxy(streaming: false) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get '/not-modified'
      assert_equal 304, last_response.status
      assert_equal '', last_response.body
    end
  end

  def test_empty_body_is_not_array_with_empty_string
    with_webrick_proxy(streaming: false) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get '/empty'
      assert_equal 200, last_response.status
      assert_equal '', last_response.body
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
  # Net::HTTP default), not VERIFY_NONE.
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

  def test_https_default_rejects_invalid_certificate
    # self-signed cert on a public test host should be rejected with the new default
    app({:streaming => false}).host = 'self-signed.badssl.com'
    error = assert_raise(OpenSSL::SSL::SSLError) { get 'https://example.com/' }
    assert_match(/certificate verify failed/, error.message)
  end

  def test_https_with_ssl_verify_none_accepts_invalid_certificate
    app({:streaming => false, :ssl_verify_none => true}).host = 'self-signed.badssl.com'
    get 'https://example.com/'
    assert last_response.ok?
  end

  # Issue #80: a :logger option should pipe Net::HTTP debug output to the
  # given sink (anything responding to #<<). We use a StringIO to capture it.
  def test_logger_captures_request_in_non_streaming
    sink = StringIO.new
    with_webrick_proxy(streaming: false, logger: sink) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get '/empty'
      assert last_response.ok?
    end
    assert_match(/GET \/empty/, sink.string,
      "expected debug output to include request line, got: #{sink.string.inspect}")
  end

  def test_logger_captures_request_in_streaming
    sink = StringIO.new
    with_webrick_proxy(streaming: true, logger: sink) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get '/empty'
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
      result = Rack::Proxy.send(:build_header_hash, [['X-Test', 'value']])
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
      get '/empty'
      assert last_response.ok?
    end
  end

  private

  def assert_no_array_header_values(streaming:)
    with_webrick_proxy(streaming: streaming) do |port, proxy|
      proxy.host = "127.0.0.1:#{port}"
      get '/echo-headers'
      array_valued = last_response.headers.select { |_, v| v.is_a?(Array) }
      assert_empty array_valued,
        "expected no Array-valued headers (#65), got: #{array_valued.inspect}"
      assert_equal 'value-here', last_response['x-custom']
    end
  end


  # Spin up a tiny WEBrick server with fixed routes so we can exercise the
  # proxy against real Net::HTTP requests without depending on a remote host.
  def with_webrick_proxy(**proxy_opts)
    require 'webrick'
    server = WEBrick::HTTPServer.new(
      Port: 0,
      BindAddress: '127.0.0.1',
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: []
    )
    server.mount_proc('/no-content')   { |_req, res| res.status = 204 }
    server.mount_proc('/not-modified') { |_req, res| res.status = 304 }
    server.mount_proc('/empty')        { |_req, res| res.body = '' }
    server.mount_proc('/echo-headers') do |_req, res|
      res['x-custom'] = 'value-here'
      res.body = 'ok'
    end
    server.mount_proc('/echo-body')    { |req, res| res.body = req.body.to_s }
    Thread.new { server.start }
    port = server.config[:Port]

    proxy = HostProxy.new(**proxy_opts)
    @app = proxy
    yield port, proxy
  ensure
    server&.shutdown
    @app = nil
  end
end
