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

  # P1-5: closing after only the head was read (the HEAD/204/304 shape) must
  # unwind the suspended request Fiber and release the connection, and the body
  # must yield nothing afterwards.
  def test_close_after_reading_headers_releases_connection
    assert_equal 200, @response.status
    assert_nothing_raised { @response.close }

    session = @response.instance_variable_get(:@session)
    assert_not_nil session
    assert !session.started?, "connection must be finished after close"

    chunks = []
    @response.body.each { |chunk| chunks << chunk }
    assert_empty chunks, "a closed response must not stream a body"
  end

  # P1-5: a client abort mid-stream (modelled by `break` out of #each) must
  # close the backend connection instead of leaking the half-read socket.
  def test_early_break_mid_stream_closes_connection
    yielded = 0
    @response.body.each do |_chunk|
      yielded += 1
      break
    end

    assert_equal 1, yielded
    session = @response.instance_variable_get(:@session)
    assert_not_nil session
    assert !session.started?, "breaking out of #each must close the backend connection"
    assert_nothing_raised { @response.close }
  end

  # Use-after-close must fail loudly, not dial a backend connection that the
  # already-latched close_connection could never release.
  def test_code_after_close_raises_without_dialing
    req = Net::HTTP::Get.new("/")
    response = Rack::HttpStreamingResponse.new(req, "127.0.0.1", @server.config[:Port])
    response.use_ssl = false

    response.close
    assert_raise(IOError) { response.status }
    assert_nil response.instance_variable_get(:@session),
      "a closed response must never dial the backend"
  end

  # A 204 (also 205/304) must release the backend connection as soon as #code is
  # read — no #close/#each needed — while #headers stays readable afterwards.
  def test_204_releases_connection_at_code
    req = Net::HTTP::Get.new("/no-content")
    response = Rack::HttpStreamingResponse.new(req, "127.0.0.1", @server.config[:Port])
    response.use_ssl = false

    assert_equal 204, response.status
    session = response.instance_variable_get(:@session)
    assert_not_nil session
    assert !session.started?, "204 must close the backend connection at #code"
    assert response.headers.size.positive?, "headers must remain readable after the auto-close"
  end

  # P1-5: gzip bodies must pass through verbatim on the direct-use path too (no
  # configure block). Without the forced decode_content=false, Net::HTTP would
  # inflate the body and desync it from the forwarded Content-Length/-Encoding.
  def test_gzip_body_passes_through_verbatim_without_configure_block
    req = Net::HTTP::Get.new("/gzip")
    response = Rack::HttpStreamingResponse.new(req, "127.0.0.1", @server.config[:Port])
    response.use_ssl = false

    assert_equal 200, response.status
    body = +""
    response.body.each { |chunk| body << chunk }
    assert_equal "\x1f\x8b".b, body.b[0, 2], "body must still be gzip-compressed on the wire"
    inflated = Zlib::GzipReader.new(StringIO.new(body.b)).read
    assert_equal ProxyTestServer::GZIP_PLAINTEXT.b, inflated.b
  end

  # The no-retry guarantee must hold on the configure-block path too, even if
  # the block itself tries to enable retries (ordering: forced after configure).
  def test_configure_block_cannot_reenable_retries
    req = Net::HTTP::Get.new("/")
    response = Rack::HttpStreamingResponse.new(req, "127.0.0.1", @server.config[:Port]) do |http|
      http.max_retries = 2
    end

    assert_equal 200, response.status
    assert_equal 0, response.instance_variable_get(:@session).max_retries,
      "max_retries must be forced to 0 after the configure block runs"
  end

  # P1-5: a Fiber is thread-affine; #close from a foreign thread must fall back
  # to hard-closing the connection (no FiberError escaping, no socket leak).
  def test_close_from_another_thread_releases_connection
    assert_equal 200, @response.status

    Thread.new { @response.close }.join

    session = @response.instance_variable_get(:@session)
    assert_not_nil session
    assert !session.started?, "cross-thread close must still release the connection"

    chunks = []
    @response.body.each { |chunk| chunks << chunk }
    assert_empty chunks, "a closed response must not stream a body"
  end

  # P1-5: an HTTP/1.0-style close-delimited body (no Content-Length, no
  # Transfer-Encoding; EOF ends the body) must stream fully without raising.
  def test_http10_eof_delimited_body_streams_fully
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      client = server.accept
      client.gets("\r\n\r\n") # consume request headers
      client.write("HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n")
      client.write("eof-delimited body")
      client.close
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      # client went away; nothing to do
    ensure
      server.close
    end

    req = Net::HTTP::Get.new("/")
    response = Rack::HttpStreamingResponse.new(req, "127.0.0.1", port)
    response.use_ssl = false

    assert_equal 200, response.status
    body = +""
    response.body.each { |chunk| body << chunk }
    assert_equal "eof-delimited body", body

    session = response.instance_variable_get(:@session)
    assert !session.started?, "connection must be finished after an EOF-delimited body"
  ensure
    thread&.join(2)
  end

  # P1-5: a HEAD request has no body to stream; the response must still expose
  # status/headers and tear down cleanly.
  def test_head_request_yields_no_body
    req = Net::HTTP::Head.new("/")
    response = Rack::HttpStreamingResponse.new(req, "127.0.0.1", @server.config[:Port])
    response.use_ssl = false

    assert_equal 200, response.status
    chunks = []
    response.body.each { |chunk| chunks << chunk }
    assert_empty chunks

    session = response.instance_variable_get(:@session)
    assert !session.started?, "connection must be finished after a body-less stream"
  end

  # P1-5: Net::HTTP retries idempotent requests on transport errors by default.
  # A retry after the response head was yielded would silently replay the
  # request and restart the body mid-stream, so streaming must never retry.
  def test_streaming_session_never_retries
    @response.status
    session = @response.instance_variable_get(:@session)
    assert_equal 0, session.max_retries,
      "a mid-stream retry would replay the request and restart the body"
  end

  # P1-5: when the backend dies mid-body (headers already forwarded), #each must
  # log, re-raise so the server aborts the transfer, and still close the
  # connection — a truncated response, never a false "complete".
  def test_midstream_backend_failure_raises_logs_and_closes
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      client = server.accept
      client.gets("\r\n\r\n") # consume request headers
      client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n")
      client.write("5\r\nhello\r\n")
      client.close # die before the terminating chunk
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      # client went away; nothing to do
    ensure
      server.close
    end

    req = Net::HTTP::Get.new("/")
    response = Rack::HttpStreamingResponse.new(req, "127.0.0.1", port)
    response.use_ssl = false
    sink = StringIO.new
    response.logger = sink

    assert_equal 200, response.status
    chunks = []
    assert_raise(EOFError) { response.body.each { |chunk| chunks << chunk } }
    assert_equal ["hello"], chunks, "chunks before the failure must be delivered"
    assert_match(/streaming backend read failed/, sink.string)

    session = response.instance_variable_get(:@session)
    assert !session.started?, "connection must be torn down after a mid-stream failure"
  ensure
    thread&.join(2)
  end
end
