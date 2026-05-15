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

  private

  # Spin up a tiny WEBrick server with fixed routes so we can exercise the
  # proxy against real Net::HTTP requests without depending on a remote host.
  def with_webrick_proxy(streaming:)
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
    Thread.new { server.start }
    port = server.config[:Port]

    proxy = HostProxy.new(streaming: streaming)
    @app = proxy
    yield port, proxy
  ensure
    server&.shutdown
    @app = nil
  end
end
