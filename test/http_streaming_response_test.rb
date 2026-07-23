require "test_helper"
require "rack/http_streaming_response"

class HttpStreamingResponseTest < Test::Unit::TestCase

  def setup
    @server, port = ProxyTestServer.start_server(ssl: false)
    req = Net::HTTP::Get.new("/")
    @response = Rack::HttpStreamingResponse.new(req, "127.0.0.1", port)
    @response.use_ssl = false
  end

  def teardown
    @server&.shutdown
  end

  def test_streaming
    # Response status
    assert_equal 200, @response.status
    assert_equal 200, @response.status

    # Headers
    headers = @response.headers

    assert headers.size.positive?

    assert_match %r{text/html}, headers["content-type"].first.downcase
    assert_equal headers["content-type"], headers["CoNtEnT-TyPe"]

    # Body
    chunks = []
    @response.body.each do |chunk|
      chunks << chunk
    end

    assert chunks.size.positive?
    chunks.each do |chunk|
      assert chunk.is_a?(String)
    end

  end

  def test_to_s
    body_string = @response.body.to_s
    assert body_string.bytesize.positive?
    content_length = @response.headers["Content-Length"]
    assert_equal content_length.first.to_i, body_string.bytesize if content_length
  end

  def test_to_s_called_twice
    body = @response.body
    assert_equal body.to_s, body.to_s
  end

end
