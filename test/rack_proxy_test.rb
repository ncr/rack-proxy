require "test_helper"
require "rack/proxy"

class RackProxyTest < Test::Unit::TestCase
  class TrixProxy < Rack::Proxy
    def rewrite_env(env)
      env["HTTP_HOST"] = "trix.pl"
      env
    end
  end
  
  def app
    TrixProxy.new
  end
  
  def test_trix
    get "/"
    assert last_response.ok?
    assert /Jacek Becela/ === last_response.body
  end

  def test_header_reconstruction
    proxy = Rack::Proxy.new

    header = proxy.send(:reconstruct_header_name, "HTTP_ABC")
    assert header == "ABC"

    header = proxy.send(:reconstruct_header_name, "HTTP_ABC_D")
    assert header == "ABC-D"
  end

  def test_extract_http_request_headers
    proxy = Rack::Proxy.new
    env = {
      'NOT-HTTP-HEADER' => 'test-value',
      'HTTP_ACCEPT' => 'text/html',
      'HTTP_CONNECTION' => nil
    }

    headers = proxy.send(:extract_http_request_headers, env)
    assert headers.key?('ACCEPT')
    assert !headers.key?('CONNECTION')
    assert !headers.key?('NOT-HTTP-HEADER')
  end

  def test_handles_missing_content_length
    assert_nothing_thrown do
      post "/", nil, "CONTENT_LENGTH" => nil
    end
  end
end
