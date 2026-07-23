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
bundle exec rake test        # full suite, fully OFFLINE, ~0.2s
LIVE=1 bundle exec rake test  # additionally runs real-internet smoke tests

# Run the suite against a specific Rack major (CI does both):
BUNDLE_GEMFILE=gemfiles/rack_3.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/rack_2.gemfile bundle exec rake test
```

The default suite must never touch the network. CI (`.github/workflows/ci.yml`)
runs the matrix Ruby 3.1–3.4 × Rack 2/3, a `ruby head` canary, and a gem-build
smoke test.

## Architecture (three core files, ~360 lines)

- **`lib/rack/proxy.rb`** — `Rack::Proxy`. The entry point: `call` →
  `rewrite_env` → `perform_request` → `rewrite_response`. `perform_request`
  extracts/forwards request headers, picks the backend, and has **two distinct
  network paths** that must stay behaviorally identical: streaming (default) and
  non-streaming (`streaming: false`). Subclasses override `rewrite_env` /
  `rewrite_response` (and sometimes `perform_request`); see `lib/rack_proxy_examples/`.
- **`lib/rack/http_streaming_response.rb`** — `HttpStreamingResponse`, the lazy
  Rack body used by the streaming path. Its `#each` streams the backend response
  and closes the connection in `ensure`.
- **`lib/net_http_hacked.rb`** — a monkey-patch of **private** `Net::HTTP`
  internals that turns block-style streaming into return-style, so the response
  can become a Rack body. This is the fragile heart of the streaming path.

## Invariants — do not regress these (each has a guarding test)

- **TLS verification defaults to `VERIFY_PEER`.** Set in **both** the streaming
  and non-streaming branches of `perform_request` as
  `@verify_mode || OpenSSL::SSL::VERIFY_PEER`. If you touch one branch, touch the
  other — they must match. This regressed to `VERIFY_NONE`-by-default for years.
  Guards: `test_ssl_default_is_verify_peer`,
  `test_https_default_rejects_invalid_certificate`.
- **Connection failures return `502`, never raise.** Guards:
  `test_connection_refused_returns_502(_streaming)`, `test_unknown_host_returns_502`.
- **Hop-by-hop headers are stripped from the response.** Guard:
  `test_response_header_included_Hop_by_hop`. (Request-side stripping is still a
  TODO — see MODERNIZATION_PLAN P0-2.)
- **No entity body for 1xx/204/304.** Guards: `test_no_entity_body_for_204/304`.
- **Non-rewindable request bodies must not raise** (Rack 3 input streams need not
  respond to `#rewind`). Guard: `test_non_rewindable_body_is_forwarded_without_raising`.
- **`X-Forwarded-For`** has `REMOTE_ADDR` appended to the inbound chain. Guard:
  `test_extract_http_request_headers`.

## Traps — things that look wrong but are load-bearing

- **Do not "clean up," modernize, or delete `net_http_hacked.rb` casually.** It
  depends on private `Net::HTTP` internals; small changes silently break
  streaming across Ruby versions. The planned replacement is a Fiber-based
  rewrite (MODERNIZATION_PLAN P1-5) — do that deliberately, with tests, not as a
  drive-by refactor.
- **Never add `webmock` or `vcr`.** They monkey-patch `net/http` and break the
  streaming path. Tests exercise real traffic against a local WEBrick server
  instead.
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
