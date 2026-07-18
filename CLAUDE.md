# Working in this repo (for AI agents and new contributors)

`rack-proxy` is a small, security-sensitive Rack middleware/app that proxies HTTP
requests to a backend and lets you rewrite the request and response. It is a
library that other apps mount — so the bar is: **safe defaults, no surprises, and
never regress the security behavior below.** Read this before changing code.

The living improvement roadmap is [`MODERNIZATION_PLAN.md`](MODERNIZATION_PLAN.md)
(prioritized P0–P3, batched). Check it before starting non-trivial work.

## Commands

```sh
bundle install
bundle exec rake test        # full suite, fully OFFLINE, ~2-3s
LIVE=1 bundle exec rake test  # additionally runs real-internet smoke tests
bundle exec standardrb       # style check, CI-blocking (--fix to autofix)
COVERAGE=1 bundle exec rake test  # SimpleCov, ratcheted floor (CI-enforced)

# Run the suite against a specific Rack major (CI does both):
BUNDLE_GEMFILE=gemfiles/rack_3.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/rack_2.gemfile bundle exec rake test
```

The default suite must never touch the network. CI (`.github/workflows/ci.yml`)
runs the matrix Ruby 3.1–3.4 × Rack 2/3, a `ruby head` canary, a gem-build
smoke test, and a blocking lint job (standardrb + coverage floor + bundler-audit).

## Architecture (two core files + a deprecated shim, ~500 lines)

- **`lib/rack/proxy.rb`** — `Rack::Proxy`. The entry point: `call` →
  `rewrite_env` → `perform_request` → `rewrite_response`. `perform_request`
  extracts/forwards request headers, picks the backend, and has **two distinct
  network paths** that must stay behaviorally identical: streaming (default) and
  non-streaming (`streaming: false`). Subclasses override `rewrite_env` /
  `rewrite_response` (and sometimes `perform_request`); see `examples/`
  (copy-paste snippets, not shipped in the gem).
- **`lib/rack/http_streaming_response.rb`** — `HttpStreamingResponse`, the lazy
  Rack body used by the streaming path. It runs the public block form of
  `Net::HTTP#request` inside a **Fiber**: the Fiber pauses once the status and
  headers are in, and `#each` resumes it to pull body chunks; `#each`/`#close`
  tear the connection down (early termination unwinds the Fiber via
  `Fiber#raise`).
- **`lib/net_http_hacked.rb`** — the *former* streaming engine: a monkey-patch
  of private `Net::HTTP` internals, now a **deprecated shim** kept for one
  release for external requirers. Nothing in the library loads it anymore; it
  warns on require. Don't build anything new on it.

## Invariants — do not regress these (each has a guarding test)

- **TLS verification defaults to `VERIFY_PEER`.** The fallback
  (`@verify_mode || OpenSSL::SSL::VERIFY_PEER`) lives in exactly ONE place —
  `configure_backend_connection` in `lib/rack/proxy.rb` — and both the streaming
  and non-streaming paths must keep going through it. Never re-introduce
  per-branch TLS setup; the duplicated version of this config shipped
  `VERIFY_NONE`-by-default for years. Guards: `test_ssl_default_is_verify_peer`,
  `test_https_default_rejects_invalid_certificate(_streaming)`.
- **Connection failures return `502`, never raise.** Guards:
  `test_connection_refused_returns_502(_streaming)`, `test_unknown_host_returns_502`.
- **Hop-by-hop headers are stripped from both the response and the forwarded
  request** (request side also drops anything named by the inbound `Connection`
  header). Guards: `test_response_header_included_Hop_by_hop`,
  `test_request_hop_by_hop_headers_are_stripped`.
- **The streaming session never retries (`max_retries = 0`).** Net::HTTP's
  default idempotent retry would silently replay the request and restart the
  body after the headers were already sent to the client. Guard:
  `test_streaming_session_never_retries`.
- **No entity body for 1xx/204/304.** Guards: `test_no_entity_body_for_204/304`.
- **Non-rewindable request bodies must not raise** (Rack 3 input streams need not
  respond to `#rewind`). Guard: `test_non_rewindable_body_is_forwarded_without_raising`.
- **`X-Forwarded-For`** has `REMOTE_ADDR` appended to the inbound chain. Guard:
  `test_extract_http_request_headers`.

## Traps — things that look wrong but are load-bearing

- **The Fiber plumbing in `HttpStreamingResponse` is deliberate — don't
  "simplify" it.** Three load-bearing choices: (1) `max_retries = 0` (see
  invariants); (2) early termination unwinds the Fiber with `StreamAborted`, a
  direct `StandardError` subclass that must never match the network-error
  classes `Net::HTTP#request` retries on/rescues, or an abort could replay the
  request; (3) the request's `@decode_content` is forced off so gzip bodies are
  forwarded verbatim (inflating them desyncs Content-Length/Content-Encoding).
  A Fiber is also thread-affine: `#close` from a foreign thread skips the unwind
  and hard-closes the socket — that fallback is intentional.
- **Never add `webmock` or `vcr` to this repo's tests.** Tests must exercise
  real Net::HTTP traffic against the local WEBrick server — request-stubbing
  layers would turn the streaming tests into fiction.
- **New tests must be offline.** Use `with_webrick_proxy` (in
  `test/rack_proxy_test.rb`) or `ProxyTestServer` (in
  `test/support/proxy_test_server.rb`). Do **not** reintroduce live-host tests;
  put anything that genuinely needs the internet behind `ENV['LIVE']` in
  `test/live_smoke_test.rb`.
- **Keep the test framework as `test-unit`.** Do not migrate to RSpec/Minitest as
  a side effect of other work.
- **The default backend is the client's own `Host` header** when no `:backend`
  is configured (`perform_request`). This is intentional but an SSRF footgun;
  hardening is tracked in MODERNIZATION_PLAN P0-4. Don't widen this behavior.

## Security posture

This is a proxy: assume request headers, the `Host`, and the backend response are
attacker-influenced. When adding a feature, ask "what does a hostile client or
backend do with this?" Prefer a safe default plus an explicit opt-in over a
convenient-but-unsafe default. See the "Security" work in MODERNIZATION_PLAN
(P0-2/4, P1-8).
