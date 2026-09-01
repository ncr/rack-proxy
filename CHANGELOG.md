# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Nothing yet.

## [1.0.2] - 2026-09-01

Housekeeping — no library behavior changes. **No action is needed by users:**
the shipped gem does not depend on `json` and was never affected by the
advisory below.

### Security

- Development dependency `json` bumped 2.21.1 → 2.21.2 to clear
  CVE-2026-71847 / GHSA-9hj4-r449-hfvc (`JSON::ResumableParser#partial_value`
  dereferences a freed input buffer on truncated duplicate-key streams).
  `json` reaches this repo only transitively (`standard` → `rubocop` → `json`)
  and lives solely in the development `Gemfile.lock`; the bump keeps the CI
  `bundler-audit` gate green.

### Changed

- Release workflow: the laggy rubygems full-index await was replaced with a
  versions-API check, so a successful publish no longer fails the run. (#142)

## [1.0.1] - 2026-07-23

Docs and housekeeping — no library behavior changes.

### Changed

- README modernized: badges, quick start, a "How it works" pipeline overview,
  grouped options, and tightened recipes.
- Removed the internal modernization roadmap document, completed by 1.0.0.
- Development dependencies refreshed (rake 13.4.2, test-unit 3.7.8,
  rack-test 2.2.0) and CI bumped to `actions/checkout@v7`. (#136–#139)

## [1.0.0] - 2026-07-18

The 2026 modernization + security-hardening release. From 1.0.0 on this
project follows SemVer strictly: breaking changes only in majors.

### Breaking changes

Read this list before upgrading from 0.8.x; everything else below is additive
or a compatible fix. See the README's "Upgrading" section for migration steps.

- **Host-derived (dynamic) backends are refused by default.** With no
  `:backend` and no `env["rack.backend"]`, requests now get `502` unless you
  pass `allow_dynamic_backend: true`. A bare `Rack::Proxy.new` is no longer an
  open proxy. Combine the opt-in with a `backend_allowed?` allowlist.
- **`net_http_hacked` is gone** — the file, `require "net_http_hacked"`, and
  the `begin_request_hacked`/`end_request_hacked` methods (see Removed).
- **The bundled examples left the gem** — `require "rack_proxy_examples/..."`
  raises `LoadError`; copy the snippets from `examples/` instead (see Removed).
- **Backend failures no longer raise.** `OpenSSL::SSL::SSLError`, `EOFError`,
  timeouts, resets, and malformed backend responses now become a `502` triplet
  instead of an exception — `rescue`-based error handling around `proxy.call`
  must inspect the status instead.
- **Hop-by-hop request headers are no longer forwarded** (`Connection`, `TE`,
  `Transfer-Encoding`, `Proxy-Authorization`, `Upgrade`, anything named by
  `Connection`).
- **gzip backend bodies are forwarded verbatim in `streaming: false` mode**
  (previously they were transparently inflated); `rewrite_response` hooks that
  read body text must inflate it themselves.
- **Supported runtimes: Ruby >= 3.0 and Rack >= 2.0, < 4** (was Ruby >= 2.6,
  rack unpinned).
- Smaller wire/API changes: body-less POST/PUT sends `Content-Length: 0` on
  the streaming path; the streaming body is thread-affine (iterate it on the
  thread that called the app, as mainstream servers do); `HttpStreamingResponse`
  raises `IOError` on use-after-close; early termination closes the backend
  connection instead of draining it.

### Security

- Refuse Host-derived backends unless `allow_dynamic_backend: true` is set
  (see Breaking changes) — closes the default open-proxy/SSRF pivot.
- Strip hop-by-hop headers from the **forwarded request** (Connection, TE,
  Transfer-Encoding, Proxy-Authorization, …, plus any header named by the inbound
  `Connection` header), closing a Content-Length/Transfer-Encoding request-smuggling
  surface. Hop-by-hop headers were previously stripped only from the response.
- Add `backend_allowed?(backend)` — an overridable per-request allowlist hook,
  consulted for every request (static backends included). A refused backend
  responds `502`.
- Add `:max_response_length` to cap the backend response size (bounds memory
  against a hostile/huge backend). Enforced incrementally while streaming.
- Add `:ca_file` / `:cert_store` so private-CA backends can be verified under the
  default `VERIFY_PEER` instead of disabling verification.
- Add `:open_timeout` / `:write_timeout` to bound connect and per-write stalls
  (previously only `:read_timeout` was configurable).

### Added

- `:min_version` / `:max_version` TLS options (mapping to `Net::HTTP#min_version=`
  / `#max_version=`). `:ssl_version` still works but is deprecated (it pins an
  exact protocol and forbids TLS 1.3).
- `HttpStreamingResponse#close` so Rack servers release the backend connection on
  early termination (HEAD, 304, client disconnect) instead of leaking it until GC.
- Opt-in request hardening: `strip_credentials: true` drops the client's
  `Cookie`/`Authorization` headers from the forwarded request, and
  `replace_x_forwarded_for: true` forwards only this hop's `REMOTE_ADDR`
  instead of appending to the client-supplied `X-Forwarded-For` chain.
- Project scaffolding: `SECURITY.md`, `CHANGELOG.md`, `CONTRIBUTING.md`,
  `CLAUDE.md`/`AGENTS.md`, GitHub Actions CI (Ruby 3.1–3.4 × Rack 2/3),
  Dependabot, issue/PR templates, SimpleCov with a ratcheted coverage floor
  (`COVERAGE=1`), and Standard (`standardrb`) + `bundler-audit` enforced by a
  CI lint job.

### Changed

- **The streaming path no longer monkey-patches `net/http`.**
  `Rack::HttpStreamingResponse` now runs the public block form of
  `Net::HTTP#request` inside a Fiber (pausing at the response head, resuming
  per body chunk), replacing the 2010-era patch of private `net/http` internals
  in `net_http_hacked.rb`. Behavioral notes: the streaming session sets
  `max_retries = 0` so a transport error can never silently replay the request
  mid-stream; early termination (client abort, HEAD, 204/304) now closes
  the backend connection immediately instead of draining the remaining body;
  and a body-less POST/PUT/PATCH on the streaming path now carries
  `Content-Length: 0` (matching the non-streaming path and plain `Net::HTTP` —
  the old patched path sent no `Content-Length` at all).
- Backend and construction failures now map to status codes instead of raising a
  `500`: `400` (malformed request URI), `501` (unknown HTTP method), `502`
  (broadened backend-error set incl. `ECONNRESET`, `EPIPE`, read/write timeouts,
  `EOFError`, `OpenSSL::SSL::SSLError`, protocol errors, and malformed backend
  responses — `Net::HTTPBadResponse` / `Net::HTTPHeaderSyntaxError`).
- gzip-encoded backend responses are forwarded verbatim (Content-Encoding and
  Content-Length preserved) instead of being transparently inflated.
- Skip all `1xx` interim responses (including `103 Early Hints`) on the streaming
  path, so a backend's `103` is no longer mistaken for the final response.
- `rack` dependency constrained to `>= 2.0, < 4`; the library now `require`s rack
  itself.
- Test suite is fully offline (local WEBrick server); the previous live-host
  tests are gated behind `LIVE=1`.

### Deprecated

- `:ssl_version` — use `:min_version` / `:max_version`.

### Removed

- `lib/net_http_hacked.rb` — the 2010-era monkey-patch of private `Net::HTTP`
  internals. The library stopped using it when streaming moved to the public
  `Net::HTTP` API (see Changed); `require "net_http_hacked"` and the
  `begin_request_hacked` / `end_request_hacked` methods are gone. If external
  code still depends on them, vendor the file from a 0.8.x release — and plan
  to migrate; it breaks under modern net/http refactors.

- The bundled examples moved from the gem load path
  (`lib/rack_proxy_examples/`) to [`examples/`](examples/) in the repository.
  `require "rack_proxy_examples/..."` no longer works — copy the example class
  into your app instead (they were never safe to require blindly: each one
  installs itself into the Rails middleware stack when Rails is booted).

## [0.8.3] - 2025

### Fixed

- Handle non-rewindable request body streams (Rack 3 input streams need not
  respond to `#rewind`). (#128)

## [0.8.2] - 2025

### Fixed

- Harden `build_header_hash` against a top-level `::Headers` constant defined by
  the host app being picked up instead of `Rack::Headers`.

## [0.8.1] - 2025

### Added

- `:logger` option, wired to `Net::HTTP#set_debug_output` for wire-level debug
  output. (#80)

## [0.8.0] - 2025

### Changed

- **BREAKING:** TLS certificate verification now defaults to `VERIFY_PEER`
  (Ruby's `Net::HTTP` default). Previous versions silently used `VERIFY_NONE` for
  HTTPS backends. Pass `ssl_verify_none: true` (or `verify_mode:`) to opt out. (#113)

### Fixed

- Return `502` on backend connection errors instead of raising; correct body
  handling for empty responses and no-entity-body statuses (1xx/204/304). (#58, #122, #123)

---

Older releases (≤ 0.7.8) predate this changelog; see the git history and tags.

[Unreleased]: https://github.com/ncr/rack-proxy/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/ncr/rack-proxy/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/ncr/rack-proxy/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/ncr/rack-proxy/compare/v0.8.3...v1.0.0
[0.8.3]: https://github.com/ncr/rack-proxy/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/ncr/rack-proxy/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/ncr/rack-proxy/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/ncr/rack-proxy/compare/v0.7.8...v0.8.0
