require "test_helper"
require "rack/proxy"

# Opt-in smoke tests that hit the real internet. The default suite is fully
# offline (see test/support/proxy_test_server.rb); run these with:
#
#   LIVE=1 bundle exec rake test
#
# They add the one check the offline suite cannot express: that the default
# VERIFY_PEER accepts a certificate trusted by the SYSTEM trust store (the
# hermetic :ca_file tests cover VERIFY_PEER success against the test CA).
class LiveSmokeTest < Test::Unit::TestCase
  class HostProxy < Rack::Proxy
    attr_accessor :host

    def rewrite_env(env)
      env["HTTP_HOST"] = host || "example.com"
      env
    end
  end

  def app
    @app ||= HostProxy.new(streaming: false, allow_dynamic_backend: true)
  end

  def setup
    omit "set LIVE=1 to run network smoke tests" unless ENV["LIVE"]
  end

  def test_proxies_to_real_http_host
    app.host = "example.com"
    get "/"
    assert last_response.ok?
    assert_match(/Example Domain/, last_response.body)
  end

  def test_default_verify_peer_accepts_valid_public_cert
    app.host = "example.com"
    get "https://example.com/"
    assert last_response.ok?, "default VERIFY_PEER should accept a valid publicly-trusted cert"
  end
end
