require "test_helper"
require "rack/proxy"

class ResponseFramingTest < Test::Unit::TestCase
  def test_transfer_encoding_with_content_length_is_rejected
    [true, false].each do |streaming|
      ["Content-Length: 4", "cOnTeNt-LeNgTh: 4\r\nConnection: Content-Length, close"].each do |fields|
        payload = "safeHTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\npoisoned"
        wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n#{fields}\r\n\r\n" \
               "#{payload.bytesize.to_s(16)}\r\n#{payload}\r\n0\r\n\r\n"
        with_response(wire, streaming) do |status, headers, body|
          assert_equal 502, status
          assert_nil headers["Content-Length"]
          assert_equal "", consume(body)
        end
      end
    end
  end

  def test_valid_chunked_and_fixed_length_responses_are_preserved
    [true, false].each do |streaming|
      ["Transfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
        "Content-Length: 5\r\n\r\nhello"].each do |framed|
        with_response("HTTP/1.1 200 OK\r\n#{framed}", streaming) do |status, headers, body|
          assert_equal 200, status.to_i
          assert_nil headers["Transfer-Encoding"]
          assert_equal framed.start_with?("Content-Length") ? "5" : nil, headers["Content-Length"]
          assert_equal "hello", consume(body)
        end
      end
    end
  end

  def test_response_connection_tokens_are_removed
    wire = "HTTP/1.1 200 OK\r\nConnection: X-Internal\r\nConnection: close, X-Other\r\n" \
           "X-Internal: secret\r\nX-Other: secret\r\nX-Public: visible\r\nContent-Length: 2\r\n\r\nok"
    [true, false].each do |streaming|
      with_response(wire, streaming) do |status, headers, body|
        assert_equal 200, status.to_i
        assert_nil headers["Connection"]
        assert_nil headers["X-Internal"]
        assert_nil headers["X-Other"]
        assert_equal "visible", headers["X-Public"]
        assert_equal "ok", consume(body)
      end
    end
  end

  def test_streaming_rejection_closes_backend_before_reading_body
    closed = Queue.new
    handler = lambda do |socket|
      socket.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n")
      closed << socket.read
    end
    ProxyTestServer.with_raw_backend(handler) do |backend|
      proxy = Rack::Proxy.new(backend: backend, read_timeout: 1)
      status, _, body = proxy.call(Rack::MockRequest.env_for("/"))
      assert_equal 502, status
      assert_equal "", consume(body)
      assert_equal "", Timeout.timeout(2) { closed.pop }
    end
  end

  private

  def with_response(wire, streaming)
    ProxyTestServer.with_raw_backend(->(socket) { socket.write(wire) }) do |backend|
      proxy = Rack::Proxy.new(backend: backend, streaming: streaming, read_timeout: 1)
      status, headers, body = proxy.call(Rack::MockRequest.env_for("/"))
      yield status, headers, body
    ensure
      body.close if body.respond_to?(:close)
    end
  end

  def consume(body)
    result = +""
    body.each { |chunk| result << chunk }
    result
  ensure
    body.close if body.respond_to?(:close)
  end
end
