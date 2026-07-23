# frozen_string_literal: true

require "webrick"
require "webrick/https"
require "socket"
require "stringio"
require "zlib"

# A tiny local WEBrick server with a fixed set of routes, used across the whole
# test suite so tests never touch the public internet. This is the ONLY approved
# way to exercise real Net::HTTP traffic in tests — do not reintroduce live-host
# tests (they are flaky, slow, and fail in CI/sandbox/offline), and do not add
# webmock/vcr (they monkey-patch net/http and break the streaming code path).
#
# Routes:
#   GET  /             -> text/html; charset=UTF-8, body contains "Example Domain"
#   GET  /cookies/set  -> sets a Set-Cookie header (?test=<value>)
#   GET  /echo-headers -> sets x-custom: value-here, body "ok"
#   POST /echo-body    -> echoes the request body verbatim
#   GET  /no-content   -> 204 No Content
#   GET  /not-modified -> 304 Not Modified
#   GET  /empty        -> 200 with an empty body
#   GET  /chunked      -> Transfer-Encoding: chunked response (hop-by-hop fixture)
module ProxyTestServer
  module_function

  # Starts a server on an ephemeral port bound to 127.0.0.1 and returns
  # [server, port]. Pass ssl: true for HTTPS with an auto-generated self-signed
  # certificate (untrusted on purpose — it exercises the VERIFY_PEER default).
  def start_server(ssl: false)
    options = {
      Port: 0,
      BindAddress: "127.0.0.1",
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: []
    }

    if ssl
      cert, key = self_signed_cert
      options[:SSLEnable]      = true
      options[:SSLCertificate] = cert
      options[:SSLPrivateKey]  = key
    end

    server = WEBrick::HTTPServer.new(**options)
    mount_routes(server)
    Thread.new { server.start }
    port = server.config[:Port]
    wait_until_listening("127.0.0.1", port)
    [server, port]
  end

  def mount_routes(server)
    server.mount_proc("/") do |_req, res|
      res.content_type = "text/html; charset=UTF-8"
      res.body = "<!doctype html><html><head><title>Example Domain</title></head>" \
                 "<body><h1>Example Domain</h1><p>Local rack-proxy test fixture.</p></body></html>"
    end

    server.mount_proc("/cookies/set") do |req, res|
      res.cookies << WEBrick::Cookie.new("test", req.query["test"] || "1")
      res.body = "cookie set"
    end

    server.mount_proc("/echo-headers") do |_req, res|
      res["x-custom"] = "value-here"
      res.body = "ok"
    end

    server.mount_proc("/echo-body") { |req, res| res.body = req.body.to_s }
    server.mount_proc("/no-content")   { |_req, res| res.status = 204 }
    server.mount_proc("/not-modified") { |_req, res| res.status = 304 }
    server.mount_proc("/empty")        { |_req, res| res.body = "" }

    server.mount_proc("/chunked") do |_req, res|
      res.chunked = true
      res.content_type = "text/plain"
      res.body = "chunk-one chunk-two"
    end

    # Always returns a gzip-encoded body with Content-Encoding: gzip, to prove
    # the proxy forwards it verbatim instead of transparently decoding it (which
    # would desync Content-Length). GZIP_PLAINTEXT is the decoded payload.
    server.mount_proc("/gzip") do |_req, res|
      res.content_type = "text/plain"
      res["content-encoding"] = "gzip"
      res.body = ProxyTestServer.gzip(GZIP_PLAINTEXT)
    end
  end

  GZIP_PLAINTEXT = ("the quick brown fox " * 32).freeze

  def gzip(string)
    io = StringIO.new
    io.set_encoding(Encoding::BINARY)
    writer = Zlib::GzipWriter.new(io)
    writer.write(string)
    writer.close
    io.string
  end

  # A self-signed certificate for 127.0.0.1, generated once per run. It is
  # deliberately NOT trusted by any CA store, so the default VERIFY_PEER rejects
  # it (that is the point of the SSL tests). Generated without a progress block
  # so OpenSSL key generation stays silent. Includes a SAN so it is reusable
  # once a :ca_file option makes the VERIFY_PEER-success path testable offline.
  def self_signed_cert
    @self_signed_cert ||= begin
      key = OpenSSL::PKey::RSA.new(2048)
      cert = OpenSSL::X509::Certificate.new
      name = OpenSSL::X509::Name.parse("/CN=127.0.0.1")
      cert.version    = 2
      cert.serial     = 1
      cert.subject    = name
      cert.issuer     = name
      cert.public_key = key.public_key
      cert.not_before = Time.now - 3600
      cert.not_after  = Time.now + (365 * 24 * 3600)

      ef = OpenSSL::X509::ExtensionFactory.new
      ef.subject_certificate = cert
      ef.issuer_certificate  = cert
      cert.add_extension(ef.create_extension("basicConstraints", "CA:TRUE", true))
      cert.add_extension(ef.create_extension("subjectAltName", "IP:127.0.0.1,DNS:localhost", false))
      cert.sign(key, OpenSSL::Digest.new("SHA256"))

      [cert, key]
    end
  end

  # WEBrick binds the listen socket in #new (so the port is known immediately),
  # but the accept loop only runs once #start is scheduled. Poll until the port
  # actually accepts a connection to remove any startup race.
  def wait_until_listening(host, port, timeout: 5)
    deadline = Time.now + timeout
    loop do
      TCPSocket.new(host, port).close
      return
    rescue SystemCallError
      raise "test server on #{host}:#{port} did not become ready" if Time.now > deadline

      sleep 0.01
    end
  end
end
