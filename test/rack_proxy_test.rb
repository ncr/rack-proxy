require "test_helper"
require "rack/proxy"

class RackProxyTest < Test::Unit::TestCase
  class HostProxy < Rack::Proxy
    attr_accessor :host

    def rewrite_env(env)
      env["HTTP_HOST"] = self.host || 'www.trix.pl'
      env
    end
  end

  def app(opts = {})
    return @app ||= HostProxy.new(opts)
  end

  def test_http_streaming
    get "/"
    assert last_response.ok?
    assert_match(/Jacek Becela/, last_response.body)
  end

  def test_http_full_request
    app(:streaming => false)
    get "/"
    assert last_response.ok?
    assert_match(/Jacek Becela/, last_response.body)
  end

  def test_http_full_request_headers
    app(:streaming => false)
    app.host = 'www.google.com'
    get "/"
    assert !Array(last_response['Set-Cookie']).empty?, 'Google always sets a cookie, yo. Where my cookies at?!'
  end

  def test_https_streaming
    app.host = 'www.apple.com'
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

  def test_header_reconstruction
    proxy_class = Rack::Proxy

    header = proxy_class.send(:reconstruct_header_name, "HTTP_ABC")
    assert header == "ABC"

    header = proxy_class.send(:reconstruct_header_name, "HTTP_ABC_D")
    assert header == "ABC-D"
  end

  def test_extract_http_request_headers
    proxy_class = Rack::Proxy
    env = {
      'NOT-HTTP-HEADER' => 'test-value',
      'HTTP_ACCEPT' => 'text/html',
      'HTTP_CONNECTION' => nil
    }

    headers = proxy_class.extract_http_request_headers(env)
    assert headers.key?('ACCEPT')
    assert !headers.key?('CONNECTION')
    assert !headers.key?('NOT-HTTP-HEADER')
  end

  def test_duplicate_headers
    proxy_class = Rack::Proxy
    env = { 'Set-Cookie' => ["cookie1=foo", "cookie2=bar"] }

    headers = proxy_class.normalize_headers(env)
    assert headers['Set-Cookie'].include?('cookie2'), "Join multiple cookies with newlines"
  end


  def test_handles_missing_content_length
    assert_nothing_thrown do
      post "/", nil, "CONTENT_LENGTH" => nil
    end
  end
end
