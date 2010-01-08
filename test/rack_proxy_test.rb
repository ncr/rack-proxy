require "test_helper"
require "rack/proxy"

class RackProxyTest < Test::Unit::TestCase
  class TrixProxy < Rack::Proxy
    def rewrite_request(req)
      req.env["HTTP_HOST"] = "trix.pl"
      
      req
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
end
