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
end
