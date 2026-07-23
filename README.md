# Rack::Proxy

A request/response rewriting HTTP proxy. A Rack app. Subclass `Rack::Proxy` and provide your `rewrite_env` and `rewrite_response` methods.

## Contents

- [Installation](#installation)
- [Use Cases](#use-cases)
- [Options](#options)
- [Security considerations](#security-considerations)
- [Examples](#examples)
- [Upgrading](#upgrading)
- [A note on header keys](#a-note-on-header-keys-96)
- [Compatibility notes](#compatibility-notes)

Installation
----

Add the following to your `Gemfile`:

```
gem 'rack-proxy', '~> 0.8.0'
```

Or install:

```
gem install rack-proxy
```

Use Cases
----

Below are some examples of real world use cases for Rack-Proxy. If you have done something interesting, add it to the list below and send a PR.

* Allowing one app to act as central trust authority
  * handle accepting self-sign certificates for internal apps
  * authentication / authorization prior to proxying requests to a blindly trusting backend
  * avoiding CORs complications by proxying from same domain to another backend
* subdomain based pass-through to multiple apps
* Complex redirect rules
   * redirect pages with different extensions (ex: `.php`) to another app
   * useful for handling awkward redirection rules for moved pages
* fan Parallel Requests: turning a single API request to [multiple concurrent backend requests](https://github.com/typhoeus/typhoeus#making-parallel-requests) & merging results.
* inserting or stripping headers required or problematic for certain clients

Options
----

Options can be set when initializing the middleware or overriding a method.

* `:streaming` - stream the backend response as it arrives (default `true`). Set to `false` to buffer the whole response before returning it (also recommended under `webmock`/`vcr` — see [Compatibility notes](#compatibility-notes)).
* `:backend` - URI (or URI-parseable string) of the backend host/port/scheme to proxy to. If not set, the destination is derived from the incoming request's `Host` — see [Security considerations](#security-considerations).
* `:read_timeout` - per-read timeout in seconds (default `60`).
* `:open_timeout` - connection-open timeout in seconds.
* `:write_timeout` - per-write timeout in seconds.
* `:ssl_verify_none` - skip TLS certificate verification. Verification is on by default (`VERIFY_PEER`) — see [Upgrading](#upgrading).
* `:verify_mode` - explicit `OpenSSL::SSL::VERIFY_*` constant; wins over `ssl_verify_none`.
* `:ca_file` - path to a PEM CA bundle used to verify the backend certificate (prefer this over disabling verification for private CAs).
* `:cert_store` - an `OpenSSL::X509::Store` used to verify the backend certificate.
* `:cert` / `:key` - client certificate and key for mutual TLS to the backend.
* `:min_version` / `:max_version` - TLS protocol range (e.g. `:TLS1_2`), mapped to `Net::HTTP#min_version=` / `#max_version=`.
* `:ssl_version` - **deprecated**; pins an exact protocol (forbids TLS 1.3). Use `:min_version` / `:max_version`.
* `:max_response_length` - cap (in bytes) on the backend response size; a larger response is refused with `502` (streaming aborts once the cap is passed).
* `:username` / `:password` - HTTP Basic credentials sent to the backend.
* `:strip_credentials` - when `true`, drop the client's `Cookie` and `Authorization` headers instead of forwarding them — see [Security considerations](#security-considerations). The strip applies **after** `rewrite_env`, so a credential injected there is stripped too; attach a proxy-owned credential with `:username`/`:password` instead.
* `:replace_x_forwarded_for` - when `true`, discard the client-supplied `X-Forwarded-For` chain and forward only this hop's `REMOTE_ADDR` (default appends to the chain) — see [Security considerations](#security-considerations).
* `:logger` - any object responding to `#<<` (e.g. `$stdout`, a `StringIO`, or a Ruby `Logger`). Wired to `Net::HTTP#set_debug_output` so the HTTP wire-level conversation is written to the sink. Useful for debugging.

Two request-scoped overrides can also be set in `env` (e.g. from `rewrite_env`):

* `env['rack.backend']` - a URI overriding `:backend` for this request.
* `env['http.read_timeout']` - override `:read_timeout` for this request.

To pass in options, when you configure your middleware you can pass them in as an optional hash.

```ruby
Rails.application.config.middleware.use ExampleServiceProxy, backend: 'http://guides.rubyonrails.org', streaming: false
```

Security considerations
----

rack-proxy forwards attacker-influenced requests to a backend and relays the backend's response. Configure and subclass it with that in mind.

* **SSRF / open proxy.** If you do **not** set `:backend`, the destination host/port/scheme is derived from the incoming request's `Host` / `X-Forwarded-Host` header. A bare `Rack::Proxy.new` will therefore proxy to *any* host a client names — including cloud metadata endpoints (`169.254.169.254`), loopback, and private ranges. Either set a fixed `:backend`, or override `backend_allowed?(backend)` to allowlist expected hosts:

    ```ruby
    class MyProxy < Rack::Proxy
      ALLOWED = %w[api.internal.example.com].freeze

      def backend_allowed?(backend)
        ALLOWED.include?(backend.host)
      end
    end
    ```

    A refused backend is answered with `502`. (Making dynamic, `Host`-derived backends opt-in by default is planned for a future major version.)

* **Credential forwarding.** All incoming `HTTP_*` headers are forwarded, including `Authorization` and `Cookie`. Don't proxy to a different trust domain with credentials attached — pass `strip_credentials: true` to drop both (or do finer-grained filtering in `rewrite_env`). Over an `http://` backend these travel in cleartext.

* **X-Forwarded-For.** rack-proxy appends `REMOTE_ADDR` to any inbound `X-Forwarded-For`. If your clients are not behind a trusted proxy, the inbound value is attacker-controlled; pass `replace_x_forwarded_for: true` to forward only the directly-connected peer's address when the backend trusts that header.

* **TLS verification** defaults to `VERIFY_PEER`. For private-CA backends use `:ca_file` / `:cert_store` rather than `ssl_verify_none: true`.

* **Resource limits.** Use `:max_response_length` plus `:open_timeout` / `:write_timeout` / `:read_timeout` to bound memory and stalls against a hostile or slow backend.

* **Hop-by-hop headers** (Connection, TE, Transfer-Encoding, Proxy-Authorization, …) are stripped from both the forwarded request and the response.

To report a vulnerability, see [SECURITY.md](SECURITY.md).

Examples
----

The snippets below (also in [`examples/`](examples/) in the repository) are meant to be **copied into your app** — e.g. into `app/middleware/` or `lib/` — and adapted. They are not shipped in the gem and cannot be `require`d from it. To mount one in Rails, copy the class into your app and add it to the middleware stack in an initializer:

```ruby
# config/initializers/proxy.rb
Rails.application.config.middleware.use ForwardHost, backend: "http://example.com"
```

### Forward request to Host and Insert Header

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

### Disable SSL session verification when proxying a server with e.g. self-signed SSL certs

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

# Pass ssl_verify_none: true to skip TLS certificate verification.
Rack::Proxy.new(ssl_verify_none: true)
```

### Rails middleware example

From [`examples/example_service_proxy.rb`](examples/example_service_proxy.rb):

```ruby
###
# This is an example of how to use Rack-Proxy in a Rails application.
#
# Setup:
# 1. rails new test_app
# 2. cd test_app
# 3. install Rack-Proxy in `Gemfile`
#    a. `gem 'rack-proxy', '~> 0.8.0'`
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

### Using as middleware to forward only some extensions to another Application

From [`examples/rack_php_proxy.rb`](examples/rack_php_proxy.rb):

Example: Proxying only requests that end with ".php" could be done like this:

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

To use the middleware, please consider the following:

1) For Rails we could add a configuration in `config/application.rb`

```ruby
  config.middleware.use RackPhpProxy, {ssl_verify_none: true}
```

2) For Sinatra or any Rack-based application:

```ruby
class MyAwesomeSinatra < Sinatra::Base
   use  RackPhpProxy, {ssl_verify_none: true}
end
```

This will allow to run the other requests through the application and only proxy the requests that match the condition from the middleware.

See tests for more examples.

### SSL proxy for SpringBoot applications debugging

Whenever you need to debug communication with external services with HTTPS protocol (like OAuth based) you have to be able to access to your local web app through HTTPS protocol too. Typical way is to use nginx or Apache httpd as a reverse proxy but it might be inconvinuent for development environment. Simple proxy server is a better way in this case. The only what we need is to unpack incoming SSL queries and proxy them to a backend. We can prepare minimal set of files to create autonomous proxy server.

Create `config.ru` file:
```ruby
#
# config.ru
#
require 'rack'
require 'rack-proxy'

class ForwardHost < Rack::Proxy
  def rewrite_env(env)
    env['HTTP_X_FORWARDED_HOST'] = env['SERVER_NAME']
    env['HTTP_X_FORWARDED_PROTO'] = env['rack.url_scheme']
    env
  end
end

run ForwardHost.new(backend: 'http://localhost:8080')
```

Create `Gemfile` file:
```ruby
source "https://rubygems.org"

gem 'thin'
gem 'rake'
gem 'rack-proxy'
```

Create `config.yml` file with configuration of web server `thin`:
```yml
---
ssl: true
ssl-key-file: keys/domain.key
ssl-cert-file: keys/domain.crt
ssl-disable-verify: false
```

Create 'keys' directory and generate SSL key and certificates files `domain.key` and `domain.crt`

Run `bundle exec thin start` for running it with `thin`'s default port.

Or use `sudo -E thin start -C config.yml -p 443` for running with default for `https://` port.

Don't forget to enable processing of `X-Forwarded-...` headers on your application side. Just add following strings to your `resources/application.yml` file.
```yml
---
server:
  tomcat:
    remote-ip-header: x-forwarded-for
    protocol-header:  x-forwarded-proto
  use-forward-headers:  true
```

Add some domain name like `debug.your_app.com` into your local `/etc/hosts` file like
```
127.0.0.1	debug.your_app.com
```

Next start the proxy and your app. And now you can access to your Spring application through SSL connection via `https://debug.your_app.com` URI in a browser.

### Using SSL/TLS certificates with HTTP connection
This may be helpful, when third-party API has authentication by client TLS certificates and you need to proxy your requests and sign them with certificate.

Just specify Rack::Proxy SSL options and your request will use TLS HTTP connection:
```ruby
# config.ru
. . .

cert_raw = File.read('./certs/rootCA.crt')
key_raw = File.read('./certs/key.pem')

cert = OpenSSL::X509::Certificate.new(cert_raw)
key = OpenSSL::PKey.read(key_raw)

use TLSProxy, cert: cert, key: key, verify_mode: OpenSSL::SSL::VERIFY_PEER, min_version: :TLS1_2
```

And rewrite host for example:
```ruby
# tls_proxy.rb
class TLSProxy < Rack::Proxy
  attr_accessor :original_request, :query_params

  def rewrite_env(env)
    env["HTTP_HOST"] = "client-tls-auth-api.com:443"
    env
  end
end
```

Upgrading
----

### 0.7.x → 0.8.0

**TLS certificate verification is now on by default.** Prior versions silently used `OpenSSL::SSL::VERIFY_NONE` whenever the backend was HTTPS, which disabled certificate checks. 0.8.0 defaults to `VERIFY_PEER` to match Ruby's `Net::HTTP`.

If you proxy to a backend with a self-signed or otherwise untrusted certificate, you'll now get an `OpenSSL::SSL::SSLError` unless you opt out explicitly:

```ruby
Rack::Proxy.new(ssl_verify_none: true)              # or
Rack::Proxy.new(verify_mode: OpenSSL::SSL::VERIFY_NONE)
```

For internal services with a private CA, prefer setting `cert`/`verify_mode` over disabling verification altogether.

A note on header keys (#96)
----

Per the standard Rack/CGI convention, header names received by your proxy are exposed in the env with underscores (`HTTP_X_CUSTOM_HEADER`), and rack-proxy rewrites them with dashes (`X-Custom-Header`) when forwarding. This conversion is lossy: by the time a request reaches rack-proxy, the upstream web server (nginx, Apache, Caddy, Puma) has already collapsed both `X-Custom-Header` and `X_Custom_Header` into the same env key, and rack-proxy cannot recover the original spelling.

If you need underscore-style headers preserved end-to-end, configure your fronting web server (e.g. `underscores_in_headers on;` in nginx, or `HTTPProtocolOptions` in Apache) — rack-proxy is not the right layer to fix this.

Compatibility notes
----

The streaming response path (the default) streams straight off the backend socket via `Net::HTTP`. Historically it relied on private `net/http` internals and did not work at all under `webmock`, `vcr`, or `fakeweb`; it now uses only the public `Net::HTTP#request` API, but those libraries still replace the real network layer, so behavior under them is not guaranteed. In tests that stub HTTP, prefer `streaming: false`.
