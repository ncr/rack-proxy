require "test_helper"
require "net_http_hacked"

class NetHttpHackedTest < Test::Unit::TestCase

  def setup
    @server, @port = ProxyTestServer.start_server(ssl: false)
  end

  def teardown
    @server&.shutdown
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
