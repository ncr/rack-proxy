# Rack::Proxy

[![Gem Version](https://img.shields.io/gem/v/rack-proxy)](https://rubygems.org/gems/rack-proxy)
[![CI](https://github.com/ncr/rack-proxy/actions/workflows/ci.yml/badge.svg)](https://github.com/ncr/rack-proxy/actions/workflows/ci.yml)
[![Downloads](https://img.shields.io/gem/dt/rack-proxy)](https://rubygems.org/gems/rack-proxy)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A request/response rewriting HTTP proxy for Rack. Run it standalone as a tiny reverse proxy, or mount it as middleware and subclass it to rewrite requests and responses in flight.

- **Streams by default** — response bodies are relayed chunk by chunk straight off the backend socket, so large responses never buffer in memory.
- **Safe by default** — TLS verification on (`VERIFY_PEER`), Host-derived backends refused unless explicitly opted in, hop-by-hop headers stripped in both directions, backend failures mapped to `502` instead of raising.
- **Small** — two files on top of plain `Net::HTTP`; the only runtime dependency is Rack.

Typical uses:

- an authenticating/authorizing gateway in front of a trusting internal backend
- serving another app from the same origin to avoid CORS complications
- subdomain- or path-based routing to multiple internal services
- redirecting awkward legacy paths (e.g. `.php` pages) to another app
- inserting or stripping headers that are required — or problematic — for certain clients

## Contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Options](#options)
- [Security considerations](#security-considerations)
- [Recipes](#recipes)
- [Upgrading](#upgrading)
- [Header keys and underscores](#header-keys-and-underscores)
- [Compatibility notes](#compatibility-notes)
- [Development](#development)

## Installation

Requires Ruby >= 3.0 and Rack 2.x or 3.x. Add to your `Gemfile`:

```ruby
gem "rack-proxy", "~> 2.0"
```

## Quick start

A standalone reverse proxy is one line of `config.ru`:

```ruby
require "rack-proxy"

run Rack::Proxy.new(backend: "http://localhost:8080")
```

As middleware, subclass it and decide per request: call `super` to proxy, or hand the request to the rest of your app:

```ruby
class ApiProxy < Rack::Proxy
  def perform_request(env)
    if env["PATH_INFO"].start_with?("/api/")
      env["HTTP_HOST"] = "api.internal.example" # most backends route on Host
      super
    else
      @app.call(env)
    end
  end
end

# Rails (config/initializers/proxy.rb):
Rails.application.config.middleware.use ApiProxy, backend: "https://api.internal.example"

# Any Rack app (config.ru or Sinatra):
use ApiProxy, backend: "https://api.internal.example"
```

## How it works

Every request runs through a three-step pipeline:

```
call(env) → rewrite_env(env) → perform_request(env) → rewrite_response([status, headers, body])
```

Override the steps you need:

- **`rewrite_env(env)`** — modify the request before it is forwarded (`HTTP_HOST`, path, headers, …). Return the env.
- **`rewrite_response(triplet)`** — post-process the backend's `[status, headers, body]`. Return the triplet. If you change the body, delete or recalculate `Content-Length` (`headers["content-length"] = nil`) or clients may receive truncated responses.
- **`perform_request(env)`** — take over routing: `super` proxies the request, `@app.call(env)` passes it through to the wrapped app (middleware mode).
- **`backend_allowed?(backend)`** — per-request allowlist hook, consulted for every request; return `false` to refuse with `502`. See [Security considerations](#security-considerations).

Two request-scoped overrides can also be set in `env` (e.g. from `rewrite_env`):

- `env["rack.backend"]` — a URI (or URI-parseable string) overriding `:backend` for this request.
- `env["http.read_timeout"]` — override `:read_timeout` for this request.

## Options

Pass options when instantiating (`Rack::Proxy.new(backend: ...)`) or mounting middleware (`use ApiProxy, backend: ...`).

### Routing and mode

- `:backend` — URI (or URI-parseable string) of the backend host/port/scheme to proxy to. If not set, the destination is derived from the incoming request's `Host` — which is **refused by default** since 1.0; see `:allow_dynamic_backend`.
- `:allow_dynamic_backend` — opt in (`true`) to deriving the destination from the client-supplied `Host` header when no `:backend` is configured. Off by default (such requests get `502`), because a bare dynamic proxy is an open proxy. Combine with a `backend_allowed?` allowlist.
- `:streaming` — stream the backend response as it arrives (default `true`). Set to `false` to buffer the whole response before returning it (also recommended under `webmock`/`vcr` — see [Compatibility notes](#compatibility-notes)).

### TLS

- `:ssl_verify_none` — skip TLS certificate verification. Verification is on by default (`VERIFY_PEER`) — see [Upgrading](#upgrading).
- `:verify_mode` — explicit `OpenSSL::SSL::VERIFY_*` constant; wins over `ssl_verify_none`.
- `:ca_file` — path to a PEM CA bundle used to verify the backend certificate (prefer this over disabling verification for private CAs).
- `:cert_store` — an `OpenSSL::X509::Store` used to verify the backend certificate.
- `:cert` / `:key` — client certificate and key for mutual TLS to the backend.
- `:min_version` / `:max_version` — TLS protocol range (e.g. `:TLS1_2`), mapped to `Net::HTTP#min_version=` / `#max_version=`.
- `:ssl_version` — **deprecated**; pins an exact protocol (forbids TLS 1.3). Use `:min_version` / `:max_version`.

### Timeouts and limits

- `:read_timeout` — per-read timeout in seconds (default `60`).
- `:open_timeout` — connection-open timeout in seconds.
- `:write_timeout` — per-write timeout in seconds.
- `:max_response_length` — cap (in bytes) on the backend response body. Oversized declared lengths are refused before reading the body, and each chunk is checked before buffering or forwarding it. Non-streaming responses return `502` on overflow; streaming responses abort if overflow is discovered after sending the headers. HEAD/304 representation lengths do not count as body bytes.

### Request shaping

- `:username` / `:password` — HTTP Basic credentials sent to the backend.
- `:strip_credentials` — when `true`, drop the client's `Cookie` and `Authorization` headers instead of forwarding them — see [Security considerations](#security-considerations). The strip applies **after** `rewrite_env`, so a credential injected there is stripped too; attach a proxy-owned credential with `:username`/`:password` instead.
- `:replace_x_forwarded_for` — when `true`, discard the client-supplied `X-Forwarded-For` chain and forward only this hop's `REMOTE_ADDR` (default appends to the chain) — see [Security considerations](#security-considerations).

### Debugging

- `:logger` — any object responding to `#<<` (e.g. `$stdout`, a `StringIO`, or a Ruby `Logger`). Wired to `Net::HTTP#set_debug_output` so the HTTP wire-level conversation is written to the sink.

## Security considerations

rack-proxy forwards attacker-influenced requests to a backend and relays the backend's response. Configure and subclass it with that in mind.

- **SSRF / open proxy — safe by default since 1.0.** If you do **not** set `:backend`, the destination host/port/scheme would be derived from the incoming request's `Host` / `X-Forwarded-Host` header — meaning a client could steer the proxy at *any* host, including cloud metadata endpoints (`169.254.169.254`), loopback, and private ranges. Such requests are now refused with `502` unless you pass `allow_dynamic_backend: true`. When you do opt in, pin an allowlist on top by overriding `backend_allowed?(backend)` (consulted for every request, static backends included):

    ```ruby
    class MyProxy < Rack::Proxy
      ALLOWED = %w[api.internal.example.com].freeze

      def backend_allowed?(backend)
        ALLOWED.include?(backend.host)
      end
    end

    MyProxy.new(allow_dynamic_backend: true)
    ```

    A refused backend is answered with `502` (with a hint in the `:logger` output).

- **Credential forwarding.** All incoming `HTTP_*` headers are forwarded, including `Authorization` and `Cookie`. Don't proxy to a different trust domain with credentials attached — pass `strip_credentials: true` to drop both (or do finer-grained filtering in `rewrite_env`). Over an `http://` backend these travel in cleartext.

- **X-Forwarded-For.** rack-proxy appends `REMOTE_ADDR` to any inbound `X-Forwarded-For`. If your clients are not behind a trusted proxy, the inbound value is attacker-controlled; pass `replace_x_forwarded_for: true` to forward only the directly-connected peer's address when the backend trusts that header.

- **TLS verification** defaults to `VERIFY_PEER`. For private-CA backends use `:ca_file` / `:cert_store` rather than `ssl_verify_none: true`.

- **Resource limits.** Use `:max_response_length` plus `:open_timeout` / `:write_timeout` / `:read_timeout` to bound memory and stalls against a hostile or slow backend.

- **Hop-by-hop headers** (Connection, TE, Transfer-Encoding, Proxy-Authorization, …) are stripped from both the forwarded request and the response.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Recipes

The snippets below (also in [`examples/`](examples/) in the repository) are meant to be **copied into your app** — e.g. into `app/middleware/` or `lib/` — and adapted. They are not shipped in the gem and cannot be `require`d from it.

### Rewrite the Host and add a response header

From [`examples/forward_host.rb`](examples/forward_host.rb):

```ruby
class ForwardHost < Rack::Proxy
  def rewrite_env(env)
    env["HTTP_HOST"] = "example.com"
    env
  end

  def rewrite_response(triplet)
    _, headers, _ = triplet

    # example of inserting an additional header
    headers["X-Foo"] = "Bar"

    # if you rewrite env, it appears that content-length isn't calculated correctly
    # resulting in only partial responses being sent to users
    # you can remove it or recalculate it here
    headers["content-length"] = nil

    triplet
  end
end
```

```ruby
# config/initializers/proxy.rb
Rails.application.config.middleware.use ForwardHost, backend: "http://example.com"
```

### Proxy to a backend with a self-signed certificate

From [`examples/trusting_proxy.rb`](examples/trusting_proxy.rb):

```ruby
class TrustingProxy < Rack::Proxy
  def rewrite_env(env)
    env["HTTP_HOST"] = "self-signed.badssl.com"
    env
  end

  def rewrite_response(triplet)
    _, headers, _ = triplet

    # if you rewrite env, it appears that content-length isn't calculated correctly
    # resulting in only partial responses being sent to users
    # you can remove it or recalculate it here
    headers["content-length"] = nil

    triplet
  end
end

# Mount it with an explicit backend (dynamic Host-derived backends are refused
# by default since 1.0). Pass ssl_verify_none: true to skip TLS verification.
Rails.application.config.middleware.use TrustingProxy,
  backend: "https://self-signed.badssl.com",
  ssl_verify_none: true
```

For a backend signed by a private CA, prefer `ca_file: "/path/to/ca.pem"` over disabling verification.

### Mount an external service under a path (Rails)

From [`examples/example_service_proxy.rb`](examples/example_service_proxy.rb):

```ruby
###
# This is an example of how to use Rack-Proxy in a Rails application.
#
# Setup:
# 1. rails new test_app
# 2. cd test_app
# 3. install Rack-Proxy in `Gemfile`
#    a. `gem 'rack-proxy', '~> 2.0'`
# 4. install gem: `bundle install`
# 5. copy the class into your app and mount it from `config/initializers/proxy.rb`
# 6. run: `SERVICE_URL=http://guides.rubyonrails.org rails server`
# 7. open in browser: `http://localhost:3000/example_service`
#
###
ENV["SERVICE_URL"] ||= "http://guides.rubyonrails.org"

class ExampleServiceProxy < Rack::Proxy
  def perform_request(env)
    request = Rack::Request.new(env)

    # use rack proxy for anything hitting our host app at /example_service
    if %r{^/example_service}.match?(request.path)
      backend = URI(ENV["SERVICE_URL"])
      # most backends required host set properly, but rack-proxy doesn't set this for you automatically
      # even when a backend host is passed in via the options
      env["HTTP_HOST"] = backend.host

      # This is the only path that needs to be set currently on Rails 5 & greater
      env["PATH_INFO"] = ENV["SERVICE_PATH"] || "/configuring.html"

      # don't send your sites cookies to target service, unless it is a trusted internal service that can parse all your cookies
      env["HTTP_COOKIE"] = ""
      super
    else
      @app.call(env)
    end
  end
end
```

### Proxy only matching requests (e.g. `.php`) as middleware

From [`examples/rack_php_proxy.rb`](examples/rack_php_proxy.rb):

```ruby
###
# Open http://localhost:3000/test.php to trigger proxy
###
class RackPhpProxy < Rack::Proxy
  def perform_request(env)
    request = Rack::Request.new(env)
    if %r{\.php}.match?(request.path)
      env["HTTP_HOST"] = ENV["HTTP_HOST"] ? URI(ENV["HTTP_HOST"]).host : "localhost"
      ENV["PHP_PATH"] ||= "/manual/en/tutorial.firstpage.php"

      # Rails 3 & 4
      env["REQUEST_PATH"] = ENV["PHP_PATH"] || "/php/#{request.fullpath}"
      # Rails 5 and above
      env["PATH_INFO"] = ENV["PHP_PATH"] || "/php/#{request.fullpath}"

      env["content-length"] = nil

      super
    else
      @app.call(env)
    end
  end

  def rewrite_response(triplet)
    _, headers, _ = triplet

    # if you proxy depending on the backend, it appears that content-length isn't calculated correctly
    # resulting in only partial responses being sent to users
    # you can remove it or recalculate it here
    headers["content-length"] = nil

    triplet
  end
end
```

Mount it in Rails (`config/application.rb`):

```ruby
config.middleware.use RackPhpProxy, backend: "http://php.net"
```

or in Sinatra / any Rack app:

```ruby
class MyAwesomeSinatra < Sinatra::Base
  use RackPhpProxy, backend: "http://php.net"
end
```

Requests matching the condition are proxied; everything else runs through your application as usual. See the tests for more examples.

### Local TLS-terminating proxy

Useful when an external integration (OAuth callbacks, webhooks) insists on talking HTTPS to your dev machine: terminate TLS locally and forward the decrypted traffic to your app running on plain HTTP.

```ruby
# config.ru
require "rack-proxy"

class ForwardProto < Rack::Proxy
  def rewrite_env(env)
    env["HTTP_X_FORWARDED_HOST"] = env["SERVER_NAME"]
    env["HTTP_X_FORWARDED_PROTO"] = env["rack.url_scheme"]
    env
  end
end

run ForwardProto.new(backend: "http://localhost:8080")
```

Generate a key/certificate pair for your dev hostname and serve the proxy over TLS, e.g. with puma:

```sh
puma -b 'ssl://0.0.0.0:9292?key=keys/domain.key&cert=keys/domain.crt' config.ru
```

Point the dev hostname at yourself (`127.0.0.1 debug.your_app.com` in `/etc/hosts`), and make sure your app honors `X-Forwarded-Host` / `X-Forwarded-Proto` from this trusted hop (e.g. `server.forward-headers-strategy: framework` in Spring Boot, or Rails' default `config.action_dispatch` handling).

### Client TLS certificates (mutual TLS)

When a third-party API authenticates clients with TLS certificates, terminate the client's request and re-sign the outgoing connection:

```ruby
# config.ru
cert = OpenSSL::X509::Certificate.new(File.read("./certs/client.crt"))
key = OpenSSL::PKey.read(File.read("./certs/key.pem"))

use TLSProxy, backend: "https://client-tls-auth-api.com",
  cert: cert, key: key, min_version: :TLS1_2
```

```ruby
# tls_proxy.rb
class TLSProxy < Rack::Proxy
  def rewrite_env(env)
    env["HTTP_HOST"] = "client-tls-auth-api.com:443"
    env
  end
end
```

## Upgrading

### 1.x → 2.0.0

2.0.0 hardens HTTP framing and response limits. Ruby and Rack requirements are unchanged.

- **Automatic transport retries are disabled in both modes.** Non-streaming requests previously inherited Net::HTTP's retry behavior. If your application needs retries, use an explicit policy that considers whether the operation is safe to replay and provides a fresh request body for each attempt.
- **Response hooks follow Rack's types.** Statuses are integers in both modes. On Rack 3, repeated headers such as `Set-Cookie` are arrays of strings; update hooks that split these values on newlines. Rack 2 still uses newline-separated strings.
- **Framing errors fail explicitly.** Malformed request lengths and incomplete uploads return `400`. Ambiguous backend framing returns `502`. A truncated backend body returns `502` before headers are sent, or raises during streaming so the server aborts the transfer. Uploads without `CONTENT_LENGTH` are forwarded with chunked encoding; backends must support HTTP/1.1 chunked requests.
- **Response limits apply before buffering.** `max_response_length` now bounds non-streaming accumulation. HEAD and 304 representation lengths do not count toward the body cap.

Update your Gemfile to `gem "rack-proxy", "~> 2.0"` and run `bundle update rack-proxy`. Existing explicit backend and TLS options continue to work.

### 0.8.x → 1.0.0

1.0.0 is a breaking release; the full list is in [CHANGELOG.md](CHANGELOG.md). The changes most likely to need action:

**Host-derived backends now require an explicit opt-in.** If you rely on the destination being derived from the request's `Host` header (no `:backend` option — this includes every subclass that routes by rewriting `env["HTTP_HOST"]`), such requests now return `502`. Restore the behavior explicitly, ideally with an allowlist:

```ruby
class MyProxy < Rack::Proxy
  def backend_allowed?(backend)
    %w[api.internal.example.com].include?(backend.host)
  end
end

MyProxy.new(allow_dynamic_backend: true)
```

Deployments with a fixed `:backend` (or that set `env["rack.backend"]` in `rewrite_env`) need no change.

**Backend failures return `502` instead of raising.** If you rescued `OpenSSL::SSL::SSLError`, `Errno::ECONNREFUSED`, timeouts, etc. around the proxy, inspect the response status instead. Malformed request URIs map to `400` and unknown HTTP methods to `501`.

**`require "rack_proxy_examples/..."` is gone.** The examples are copy-paste snippets in [`examples/`](examples/) now — copy the class into your app and mount it yourself.

**`net_http_hacked` is gone.** The library streams via the public `Net::HTTP` API; if external code called `begin_request_hacked`/`end_request_hacked`, vendor the old file from a 0.8.x release and plan a migration.

**Other behavior changes to be aware of:** hop-by-hop request headers (including `Proxy-Authorization`) are no longer forwarded; gzip bodies are forwarded still-compressed in `streaming: false` mode (inflate in `rewrite_response` if you inspect body text); body-less POST/PUT sends `Content-Length: 0`; Ruby >= 3.0 and Rack 2.x–3.x are required.

### 0.7.x → 0.8.0

**TLS certificate verification is now on by default.** Prior versions silently used `OpenSSL::SSL::VERIFY_NONE` whenever the backend was HTTPS, which disabled certificate checks. 0.8.0 defaults to `VERIFY_PEER` to match Ruby's `Net::HTTP`.

If you proxy to a backend with a self-signed or otherwise untrusted certificate, you'll now get an `OpenSSL::SSL::SSLError` unless you opt out explicitly:

```ruby
Rack::Proxy.new(ssl_verify_none: true)              # or
Rack::Proxy.new(verify_mode: OpenSSL::SSL::VERIFY_NONE)
```

For internal services with a private CA, prefer setting `ca_file`/`cert_store` over disabling verification altogether.

## Header keys and underscores

Per the standard Rack/CGI convention, header names received by your proxy are exposed in the env with underscores (`HTTP_X_CUSTOM_HEADER`), and rack-proxy rewrites them with dashes (`X-Custom-Header`) when forwarding. This conversion is lossy: by the time a request reaches rack-proxy, the upstream web server (nginx, Apache, Caddy, Puma) has already collapsed both `X-Custom-Header` and `X_Custom_Header` into the same env key, and rack-proxy cannot recover the original spelling (see [#96](https://github.com/ncr/rack-proxy/issues/96)).

If you need underscore-style headers preserved end-to-end, configure your fronting web server (e.g. `underscores_in_headers on;` in nginx, or `HTTPProtocolOptions` in Apache) — rack-proxy is not the right layer to fix this.

## Compatibility notes

The streaming response path (the default) streams straight off the backend socket via `Net::HTTP`. Historically it relied on private `net/http` internals and did not work at all under `webmock`, `vcr`, or `fakeweb`; it now uses only the public `Net::HTTP#request` API, but those libraries still replace the real network layer, so behavior under them is not guaranteed. In tests that stub HTTP, prefer `streaming: false`.

## Development

```sh
bundle install
bundle exec rake test            # full suite, fully offline, ~2-3s
LIVE=1 bundle exec rake test     # additionally runs real-internet smoke tests
bundle exec standardrb           # style check (CI-blocking)
```

Bug reports and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow and [CLAUDE.md](CLAUDE.md) for the invariants every change must preserve. Release history lives in [CHANGELOG.md](CHANGELOG.md).

## License

Released under the [MIT License](LICENSE).
