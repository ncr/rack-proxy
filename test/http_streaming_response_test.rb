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

  # P0-1: Rack servers call body.close; it must be public.
  def test_body_responds_to_close
    assert @response.body.respond_to?(:close)
  end

  # P0-1: closing a response whose body was never read must NOT dial the backend
  # just to tear it down (i.e. it must not trigger the lazy session).
  def test_close_without_reading_opens_no_connection
    req = Net::HTTP::Get.new("/")
    response = Rack::HttpStreamingResponse.new(req, "127.0.0.1", @server.config[:Port])
    response.use_ssl = false
    assert_nothing_raised { response.close }
    assert_nil response.instance_variable_get(:@session), "close must not open a session"
  end

  # P0-1: after streaming, the backend connection must be finished, and close
  # must be idempotent.
  def test_close_releases_connection_after_reading
    @response.body.each { |_chunk| }
    session = @response.instance_variable_get(:@session)
    assert_not_nil session
    assert !session.started?, "backend connection must be finished after streaming"
    assert_nothing_raised { @response.close }
  end

end
