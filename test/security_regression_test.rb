require "test_helper"
require "rack/proxy"
require "rack/lint"

class SecurityRegressionTest < Test::Unit::TestCase
  class DeadlineExceeded < StandardError; end

  class NonRewindableInput < StringIO
    undef_method :rewind
  end

  def test_unknown_length_upload_is_reframed_without_losing_the_body
    server, port = ProxyTestServer.start_server
    payload = "GET /injected HTTP/1.1\r\nHost: internal\r\n\r\n"
    [true, false].each do |streaming|
      [nil, "chunked"].each do |encoding|
        proxy = Rack::Proxy.new(backend: "http://127.0.0.1:#{port}", streaming: streaming)
        env = Rack::MockRequest.env_for("/echo-body", method: "POST")
        env.delete("CONTENT_LENGTH")
        env["CONTENT_TYPE"] = "text/plain"
        env["HTTP_TRANSFER_ENCODING"] = encoding
        env["rack.input"] = NonRewindableInput.new(payload)
        status, _, body = proxy.call(env)
        assert_equal 200, status
        assert_equal payload, consume(body), "decoded input must remain the POST body"
      end
    end
  ensure
    server&.shutdown
  end

  def test_content_length_bounds_bytes_written_to_backend
    [true, false].each do |streaming|
      received = Queue.new
      handler = lambda do |socket|
        data = socket.read(5)
        data << socket.readpartial(4096) if IO.select([socket], nil, nil, 0.02)
        received << data
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
      end
      ProxyTestServer.with_raw_backend(handler) do |backend|
        env = Rack::MockRequest.env_for("/", method: "POST")
        env["CONTENT_LENGTH"] = "5"
        env["CONTENT_TYPE"] = "text/plain"
        env["rack.input"] = StringIO.new("helloGET /injected HTTP/1.1\r\nHost: internal\r\n\r\n")
        proxy = Rack::Proxy.new(backend: backend, streaming: streaming)
        status, _, body = proxy.call(env)
        assert_equal 200, status
        assert_equal "ok", consume(body)
        assert_equal "hello", received.pop, "bytes after Content-Length must never reach the backend"
      end
    end
  end

  def test_invalid_request_lengths_return_400
    [true, false].each do |streaming|
      ["-1", "5garbage", "5, 6", ""].each do |length|
        env = Rack::MockRequest.env_for("/", method: "POST", input: "hello")
        env["CONTENT_LENGTH"] = length
        assert_equal 400, Rack::Proxy.new(streaming: streaming).call(env).first
      end
    end
  end

  def test_short_request_body_returns_400_and_closes_backend
    [true, false].each do |streaming|
      handler = ->(socket) { socket.read }
      ProxyTestServer.with_raw_backend(handler) do |backend|
        env = Rack::MockRequest.env_for("/", method: "POST", input: "hello")
        env["CONTENT_LENGTH"] = "10"
        env["CONTENT_TYPE"] = "text/plain"
        proxy = Rack::Proxy.new(backend: backend, streaming: streaming)
        assert_equal 400, proxy.call(env).first
      end
    end
  end

  def test_ambiguous_and_unsupported_response_framing_returns_502
    fields = [
      "Transfer-Encoding: chunked\r\nContent-Length: 1",
      "Transfer-Encoding: gzip, chunked",
      "Content-Length: 2\r\nContent-Length: 3",
      "Content-Length: 2, 3",
      "Content-Length: 2junk",
      "Content-Length: -1"
    ]
    [true, false].each do |streaming|
      fields.each do |headers|
        with_response("HTTP/1.1 200 OK\r\n#{headers}\r\n\r\n", streaming: streaming) do |proxy|
          status, _, body = proxy.call(Rack::MockRequest.env_for("/"))
          assert_equal 502, status, headers
          assert_equal "", consume(body)
        end
      end
    end
  end

  def test_equal_duplicate_content_lengths_are_normalized
    [true, false].each do |streaming|
      with_response("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\nok", streaming: streaming) do |proxy|
        status, headers, body = proxy.call(Rack::MockRequest.env_for("/"))
        assert_equal 200, status
        assert_equal "2", headers["Content-Length"]
        assert_equal "ok", consume(body)
      end
    end
  end

  def test_response_connection_tokens_are_removed_across_multiple_fields
    wire = "HTTP/1.1 200 OK\r\nConnection: X-Internal\r\nConnection: close, X-Other\r\n" \
           "X-Internal: secret\r\nX-Other: secret\r\nX-End-To-End: public\r\nContent-Length: 2\r\n\r\nok"
    [true, false].each do |streaming|
      with_response(wire, streaming: streaming) do |proxy|
        _, headers, body = proxy.call(Rack::MockRequest.env_for("/"))
        %w[Connection X-Internal X-Other].each { |key| assert_nil headers[key] }
        assert_equal "public", headers["X-End-To-End"]
        assert_equal "ok", consume(body)
      end
    end
  end

  def test_truncated_content_length_response_is_never_successful
    [true, false].each do |streaming|
      with_response("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhello", streaming: streaming) do |proxy|
        status, _, body = proxy.call(Rack::MockRequest.env_for("/"))
        if streaming
          assert_equal 200, status
          assert_raise(EOFError) { consume(body) }
          assert !body.instance_variable_get(:@session).started?
        else
          assert_equal 502, status
          assert_equal "", consume(body)
        end
      end
    end
  end

  def test_buffered_response_limit_aborts_before_reading_the_whole_body
    # Neither response completes: a size cap must close the connection without
    # waiting for the rest of a declared or chunked body to arrive.
    ["Content-Length: 100\r\n\r\n",
      "Connection: Content-Length\r\nContent-Length: 100\r\n\r\n",
      "Transfer-Encoding: chunked\r\n\r\nB\r\nhello world\r\n"].each do |prefix|
      handler = lambda do |socket|
        socket.write("HTTP/1.1 200 OK\r\n#{prefix}")
        socket.read
      end
      ProxyTestServer.with_raw_backend(handler) do |backend|
        proxy = Rack::Proxy.new(backend: backend, streaming: false, max_response_length: 10)
        Timeout.timeout(2, DeadlineExceeded) do
          assert_equal 502, proxy.call(Rack::MockRequest.env_for("/")).first
        end
      end
    end
  end

  def test_backend_failure_does_not_replay_request_in_either_mode
    [true, false].each do |streaming|
      handler = ->(socket) { socket.close }
      ProxyTestServer.with_raw_backend(handler) do |backend|
        proxy = Rack::Proxy.new(backend: backend, streaming: streaming)
        # A retry would connect to the still-listening socket without a handler
        # and stall. The first failed exchange must return immediately.
        Timeout.timeout(2, DeadlineExceeded) do
          assert_equal 502, proxy.call(Rack::MockRequest.env_for("/")).first
        end
      end
    end
  end

  def test_rejected_streaming_response_closes_backend_connection
    ["Content-Length: 100", "Transfer-Encoding: chunked\r\nContent-Length: 1"].each do |headers|
      closed = Queue.new
      handler = lambda do |socket|
        socket.write("HTTP/1.1 200 OK\r\n#{headers}\r\n\r\n")
        closed << socket.read
      end
      ProxyTestServer.with_raw_backend(handler) do |backend|
        proxy = Rack::Proxy.new(backend: backend, max_response_length: 10)
        Timeout.timeout(2, DeadlineExceeded) do
          assert_equal 502, proxy.call(Rack::MockRequest.env_for("/")).first
          assert_equal "", closed.pop, "rejecting headers must release the suspended stream's socket"
        end
      end
    end
  end

  def test_head_response_size_limit_does_not_limit_representation_size
    [true, false].each do |streaming|
      with_response("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n", streaming: streaming, max_response_length: 10) do |proxy|
        status, headers, body = proxy.call(Rack::MockRequest.env_for("/", method: "HEAD"))
        assert_equal 200, status
        assert_equal "100", headers["Content-Length"]
        assert_equal "", consume(body)
      end
    end
  end

  def test_responses_pass_rack_lint_in_both_modes
    [true, false].each do |streaming|
      [200, 204, 304].each do |code|
        wire = "HTTP/1.1 #{code} Test\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\n" \
               "Content-Type: text/plain\r\nContent-Length: 2\r\n\r\n"
        wire << "ok" if code == 200
        with_response(wire, streaming: streaming) do |proxy|
          status, headers, body = Rack::Lint.new(proxy).call(Rack::MockRequest.env_for("/"))
          assert_equal code, status
          assert_equal((code == 200) ? "ok" : "", consume(body))
          cookies = headers["set-cookie"] || headers["Set-Cookie"]
          assert_equal ["a=1", "b=2"], cookies.is_a?(Array) ? cookies : cookies.split("\n")
        end
      end
    end
  end

  private

  def consume(body)
    result = +"".b
    body.each { |chunk| result << chunk }
    result
  ensure
    body.close if body.respond_to?(:close)
  end

  def with_response(wire, **options)
    ProxyTestServer.with_raw_backend(->(socket) { socket.write(wire) }) do |backend|
      yield Rack::Proxy.new(backend: backend, **options)
    end
  end
end
