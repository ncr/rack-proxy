# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

This entry collects the 2026 modernization + security-hardening work (see
`MODERNIZATION_PLAN.md`). It is not yet released.

### Security

- Strip hop-by-hop headers from the **forwarded request** (Connection, TE,
  Transfer-Encoding, Proxy-Authorization, …, plus any header named by the inbound
  `Connection` header), closing a Content-Length/Transfer-Encoding request-smuggling
  surface. Hop-by-hop headers were previously stripped only from the response.
- Add `backend_allowed?(backend)` — an overridable SSRF guardrail. It defaults to
  allowing any backend (backward compatible); override it to allowlist expected
  hosts when the destination is derived from the client `Host` header. A refused
  backend responds `502`.
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
  `CLAUDE.md`/`AGENTS.md`, GitHub Actions CI (Ruby 3.1–3.4 × Rack 2/3), Dependabot.

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
- `require "net_http_hacked"` — the monkey-patch is no longer used by the
  library. The file remains as a functional shim that warns on require, and
  will be removed in a future release.

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

[Unreleased]: https://github.com/ncr/rack-proxy/compare/v0.8.3...HEAD
[0.8.3]: https://github.com/ncr/rack-proxy/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/ncr/rack-proxy/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/ncr/rack-proxy/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/ncr/rack-proxy/compare/v0.7.8...v0.8.0
