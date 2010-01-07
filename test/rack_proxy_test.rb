require "vendor/gems/environment"
Bundler.require_env(:test)

require "test/unit"
require "rack/proxy"

class RackProxyTest < Test::Unit::TestCase
  include Rack::Test::Methods
  
  def app
    Rack::Proxy.new
  end
  
  def test_fails
    get "/"
  end
end
