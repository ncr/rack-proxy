require "test_helper"
require "stringio"

# net_http_hacked is a DEPRECATED SHIM (see lib/net_http_hacked.rb): Rack::Proxy
# no longer uses it, but it is kept working for one release for external code
# that requires it directly. This file guards both halves of that contract —
# requiring it warns, and the hacked methods still function until removal.
#
# The shim warns at require time, so capture stderr around the require both to
# assert the deprecation is emitted and to keep the suite output clean.
captured = StringIO.new
original_stderr = $stderr
begin
  $stderr = captured
  NET_HTTP_HACKED_FRESHLY_REQUIRED = require "net_http_hacked"
ensure
  $stderr = original_stderr
end
NET_HTTP_HACKED_REQUIRE_WARNING = captured.string

class NetHttpHackedTest < Test::Unit::TestCase
  def setup
    @server, @port = ProxyTestServer.start_server(ssl: false)
  end

  def teardown
    @server&.shutdown
  end

  # P1-5: requiring the shim must say loudly that it is deprecated.
  def test_require_emits_deprecation_warning
    omit "net_http_hacked was already loaded by another file" unless NET_HTTP_HACKED_FRESHLY_REQUIRED
    assert_match(/DEPRECATION.*net_http_hacked/m, NET_HTTP_HACKED_REQUIRE_WARNING)
  end

  # P1-5: the library itself must NOT load the shim — if a stray require creeps
  # back into lib/, this fails hard (in-process tests can't see it because this
  # very file loads the shim). Runs in a subprocess for isolation.
  def test_library_does_not_load_the_shim
    lib = File.expand_path("../lib", __dir__)
    out = IO.popen(
      [RbConfig.ruby, "-I", lib, "-e",
        'require "rack/proxy"; print Net::HTTP.method_defined?(:begin_request_hacked) ? "LOADED" : "CLEAN"'],
      err: [:child, :out], &:read
    )
    assert_match(/CLEAN\z/, out, "requiring rack/proxy must not load the deprecated net_http_hacked shim")
    assert_not_match(/DEPRECATION/, out, "requiring rack/proxy must not emit the shim deprecation warning")
  end

  def test_net_http_hacked
    req = Net::HTTP::Get.new("/")
    http = Net::HTTP.start("127.0.0.1", @port)

    # Response code
    res = http.begin_request_hacked(req)
    assert res.code == "200"

    # Headers
    headers = {}
    res.each_header { |k, v| headers[k] = v }

    assert headers.size > 0
    assert headers["content-type"] == "text/html; charset=UTF-8"
    assert !headers["date"].nil?

    # Body
    chunks = []
    res.read_body do |chunk|
      chunks << chunk
    end

    assert chunks.size > 0
    chunks.each do |chunk|
      assert chunk.is_a?(String)
    end

    http.end_request_hacked
  end
end
