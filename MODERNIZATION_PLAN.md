# rack-proxy — 2026 Modernization + Hardening Roadmap

> **Progress:** Batch 1 (green loop) — DONE on branch `modernization/batch-1-green-loop`.
> Batch 2 (all six P0 security fixes + P1-4 config dedup) — DONE on branch
> `modernization/batch-2-security`, each with a regression test on the offline harness.
> Remaining: Batch 3 (modernization & hardening) and Batch 4 (docs, supply-chain, polish).

Baseline already in place (do **not** redo): VERIFY_PEER default (proxy.rb:149/158), 502-on-connect-error mapping (proxy.rb:172), Rack 3 `Headers`/Rack 2 `HeaderHash` branch (proxy.rb:44-50), non-rewindable body guard (proxy.rb:131), `:logger` option. Everything below builds on that.

Effort key: **S** ≤ ½ day · **M** ~1-2 days · **L** ~several days. `[agent-DX]` = directly serves the goal of a repo that is easy + safe for AI agents to work in.

---

## P0 — Security / correctness (do first)

1. **Release the backend connection on early termination — add `HttpStreamingResponse#close`** (S)
   The streaming body (the default, proxy.rb:73) returns `self` but defines no public `#close` (http_streaming_response.rb:19-21; `close_connection` is private at :75), so HEAD requests, 304s, 1xx, and client aborts leak one backend socket/FD per request until GC — a gradual self-DoS.
   **Do:** `def close; close_connection if @session; end` (the `@session` guard prevents opening a fresh connection on a never-read response). Test: read status+headers without iterating the body, call `close`, assert the session is not `started?`; assert `close` on a fresh response opens no connection.

2. **Strip hop-by-hop headers on the *forwarded request* — close the CL/TE smuggling desync** (M)
   `HOP_BY_HOP_HEADERS` is applied only to responses (proxy.rb:181); `extract_http_request_headers` (proxy.rb:22-32) relays client `Connection`/`TE`/`Transfer-Encoding` verbatim, and with `content_length = nil.to_i => 0` (proxy.rb:129) the backend receives **both** `Transfer-Encoding: chunked` and `Content-Length: 0` — a reproduced request-smuggling primitive violating RFC 7230.
   **Do:** filter `HOP_BY_HOP_HEADERS` symmetrically in `extract_http_request_headers`; drop every header named in the inbound `Connection` header; never forward a client `Transfer-Encoding`. This also strips request-side `Proxy-Authorization` while leaving end-to-end `Authorization`/`Cookie` intact. Regression test: emitted request carries neither a forwarded TE nor a conflicting CL, and a `Connection`-named header is not forwarded.
   **Also (surfaced by the Batch 1 Rack 2 CI matrix):** the *response*-side strip at proxy.rb:181 uses `headers.reject!`, which on Rack 2's `Rack::Utils::HeaderHash` removes the pair but leaves the case-insensitive `@names` index stale — so the header is correctly omitted from the emitted response but `#key?`/`#[]` on the returned hash still report it present, misleading any downstream middleware. Switch `reject!` to `delete` (which HeaderHash overrides correctly). Not a client-facing leak, but fix it as part of this item.

3. **Broaden + relocate error handling so backend failures return 502, never raw 500s** (M)
   The rescue at proxy.rb:172 catches only six classes — `Errno::ECONNRESET`/`EPIPE`, `Net::ReadTimeout`/`WriteTimeout`, `EOFError`, `OpenSSL::SSL::SSLError` escape as 500s; construction at :116 (`URI.parse`), :121 (`const_get` → `NameError` on odd verbs), :124 (`initialize_http_header` → `ArgumentError` on CR/LF) sits *above* the `begin`; and mid-stream failures raise inside the server during `body.each` (http_streaming_response.rb:36-42).
   **Do:** broaden the rescue → static 502; guard the three construction sites (400 for malformed URI, 501 for unknown method); wrap streaming `#each` to log + close cleanly (a 502 is impossible once headers are sent); make `close_connection` defensive so its drain-on-close can't raise a second exception that masks the first.

4. **Add a backend-allowlist hook; stop defaulting the destination to the client Host (open-proxy / SSRF)** (M)
   With no `:backend`, proxy.rb:137 (`backend = env.delete('rack.backend') || @backend || source_request`) connects to `backend.host`/`port` derived from the client-controlled `Host`/`X-Forwarded-Host` header (:145,:154) with zero validation — a bare `Rack::Proxy.new` is an SSRF pivot to `169.254.169.254`/loopback/RFC1918. Static-`:backend` deployments are unaffected.
   **Do:** add an overridable `backend_allowed?(uri)` predicate (default-allow only when `@backend` is explicitly set) and/or an `allow_dynamic_backend: true` opt-in; return 502/403 when the resolved target fails or dynamic mode isn't opted into. Document the risk (metadata/loopback/private ranges).

5. **Fix streaming 103 Early Hints handling (backend 103 returned as the final response)** (S)
   The vendored request loop skips only `Net::HTTPContinue` (net_http_hacked.rb:53-54) while modern net/http loops over the whole `HTTPInformation` family, so a backend's `103 Early Hints` becomes the final response and proxy.rb:177 then blanks its body — on the *default* streaming path.
   **Do:** loop on `Net::HTTPInformation` (guarded with `const_defined?` for old Rubies); WEBrick regression test sending `103` then `200`. Interim fix, superseded by the Fiber rewrite (P1-5).

6. **Fix non-streaming gunzip / stale Content-Length desync** (S)
   proxy.rb:121 builds the request with `decode_content = true`; `initialize_http_header` (:124) doesn't clear it, so in `streaming: false` mode (the README-recommended path) Net::HTTP inflates a gzipped backend body while proxy.rb:169 forwards the original **compressed** Content-Length — truncated bodies and a CL/body desync behind keep-alive front-ends. (Single-reviewer finding, not adversarially verified, but concrete and cheap.)
   **Do:** after :124, force pass-through via `target_request['accept-encoding'] = source_request... || 'identity'` (assignment through `#[]=` sets `decode_content=false`). WEBrick test serving gzip asserts byte-identical body+headers in both modes.

---

## P1 — High-value modernization & hardening

1. **Make the test suite hermetic and offline-by-default** (L) `[agent-DX]`
   15 of 35 tests hit 6 live hosts (example.com, httpbin.org, www.apple.com with a brittle marketing-copy regex, mockapi.io, self-signed.badssl.com, www.iana.org) — 43% can't run in CI/sandbox/agent envs, the badssl tests are the *only* VERIFY_PEER regression coverage, and the mockapi hop-by-hop test passes even fully offline. `with_webrick_proxy` already exists (rack_proxy_test.rb:332-357).
   **Do:** promote `with_webrick_proxy` into `test/test_helper.rb` with an `ssl: true` mode (ephemeral in-memory self-signed cert, IP SAN for 127.0.0.1); migrate all 15 tests (fix the vacuous mockapi test with `res.chunked = true`); make `rake test` offline by default with an `ENV['LIVE']` smoke test. **Prerequisite for CI and for verifying every P0 fix.**

2. **Stand up GitHub Actions CI (Ruby × Rack 2/3 matrix); delete `.travis.yml`** (M) `[agent-DX — CI is the agent's ground truth]`
   The only CI is a dead `.travis.yml` pinned to Ruby 2.0-2.3 (:8-14), contradicting gemspec `>= 2.6`; no workflow exists, so the Rack 2 branch (proxy.rb:44-50, `Utils::HeaderHash`) never executes (Gemfile.lock resolves rack 3.2.6) and can rot silently.
   **Do:** add `.github/workflows/ci.yml`, matrix `ruby [3.1-3.4] × gemfile [rack2, rack3]` via `gemfiles/` + `BUNDLE_GEMFILE`, `bundler-cache: true`, `fail-fast: false`, `ruby: head` as a non-blocking canary; add a gem-build smoke step and `.github/dependabot.yml` (bundler + github-actions). Land after P1-1.

3. **Add `CLAUDE.md` / `AGENTS.md` documenting invariants, commands, and traps** (S) `[agent-DX]`
   No agent/contributor guide exists; the security-load-bearing invariants and the "don't touch this" traps are undiscoverable, so a plausible refactor can silently regress CVE-class behavior.
   **Do:** write `CLAUDE.md` (symlink `AGENTS.md`): 3-file architecture map; `bundle exec rake test` + the offline story; the INVARIANTS list each with its guarding test — VERIFY_PEER default duplicated at proxy.rb:149/158 (**keep both in sync**), hop-by-hop stripping, 502-never-raise, XFF append, the SSRF backend fallback (:137), non-rewindable body guard (:131); and the traps: don't "clean up" `net_http_hacked`, never add webmock/vcr (they break the streaming patch), keep test-unit, new tests use `with_webrick_proxy` only.

4. **Deduplicate the two Net::HTTP config paths into one source of truth** (M) `[agent-DX — most likely agent-caused security regression]`
   `use_ssl`/`read_timeout`/`ssl_version`/`verify_mode` (+ VERIFY_PEER fallback)/`cert`/`key`/`logger` are hand-set in three places (proxy.rb:146-152, :155-161, http_streaming_response.rb:57-66) — exactly the shape that shipped VERIFY_NONE-by-default for years (commit fca899c) — and the *default* streaming path's `verify_mode` has zero test coverage.
   **Do:** extract `configure_http(http)` consumed by both branches; have `HttpStreamingResponse` accept the config bundle/factory (note `#session` eagerly calls `http.start`, so inject a factory or split config from connect). Add offline tests asserting effective `verify_mode == VERIFY_PEER` on **both** paths.

5. **Retire `lib/net_http_hacked.rb` for a public-API Fiber-based streamer** (L)
   The patch reimplements private net/http internals (`begin_transport`, `@socket`, `@curr_http_version`, `read_new`; net_http_hacked.rb:49-64) copied from ~1.9-era code, has already drifted (1xx, EPIPE, decode_content), and is the default path.
   **Do:** rewrite `HttpStreamingResponse` to run `Net::HTTP#request(req) { |res| … }` inside a Fiber — `Fiber.yield` the response at headers, resume from `#each` to yield `read_body` chunks, close in `ensure`. Inherits upstream 1xx/EPIPE/keep-alive handling and deletes the patch (one-release deprecation shim at the old require path). Interim: keep the P0-5 fix plus a load-time private-API guard (`Net::HTTP.private_method_defined?(:begin_transport)` etc.).

6. **Add `:ca_file`/`:cert_store` TLS options + the keystone hermetic VERIFY_PEER-success test** (M)
   No CA options exist (grep: zero hits in lib/), so private-CA users are funneled to `ssl_verify_none: true` — which the README itself recommends (lines 24, 94-120, 217) — and the only positive-verification test hits live www.apple.com.
   **Do:** wire `http.ca_file`/`http.cert_store` on both paths (new accessors at http_streaming_response.rb:13); add a test CA + `127.0.0.1` leaf, extend the WEBrick SSL helper, and assert default VERIFY_PEER *succeeds* with `ca_file` and *fails* (`SSLError`) with the wrong CA. Update the README to prefer `ca_file` over disabling verification.

7. **Constrain the `rack` dependency and `require "rack"` in the library** (S)
   gemspec:22 leaves rack unpinned (may resolve rack 1.x or a breaking future 4.0), and lib/rack/proxy.rb:1-2 never requires rack despite using `Rack::Request`/`Utils`/`Headers` — `require "rack-proxy"` alone raises `NameError`, working today only by Rails load order.
   **Do:** `s.add_dependency "rack", ">= 2.0", "< 4"`; add `require "rack"` at the top of lib/rack/proxy.rb (and fix `http_streaming_response.rb`'s dependence on `Rack::Proxy.build_header_hash`).

8. **Add a SECURITY section (README) + `SECURITY.md` threat model** (M) `[agent-DX — stops agents copying unsafe shapes]`
   The README has no security guidance and advertises a "blindly trusting backend" (README:24-25); the SSRF sink (proxy.rb:137), XFF pass-through (:29-31), and full credential forwarding of `Cookie`/`Authorization` (:22-32, cleartext to http:// backends) are undocumented, and every example teaches the `HTTP_HOST`-rewrite pattern with no allowlist caveat.
   **Do:** add "Security considerations" to the README (open-proxy/SSRF, XFF trust, credential+cleartext forwarding, redirect passthrough, and the safe defaults already shipped) cross-linked to `:backend`/`rewrite_env`; document the server-only `rack.backend`/`http.read_timeout` env keys. Create `SECURITY.md` (supported versions, disclosure channel + SLA, library-vs-misconfig scope) and enable GitHub Private Vulnerability Reporting.

9. **Supply-chain hardening: gemspec metadata + MFA + Trusted Publishing + CHANGELOG** (M)
   gemspec:5-26 has no metadata block, releases are manual `rake release` with a stored key (Rakefile:3), and there's no CHANGELOG for a 173M-download gem that just shipped a breaking TLS-default change in 0.8.0.
   **Do:** add `s.metadata` (`rubygems_mfa_required`, `source_code_uri`, `changelog_uri`, `bug_tracker_uri`, `funding_uri`); create `CHANGELOG.md` (Keep-a-Changelog) backfilled 0.8.0-0.8.3; configure a rubygems.org Trusted Publisher + `.github/workflows/release.yml` (OIDC, tag-triggered, protected `release` env) and revoke the long-lived push key.

---

## P2 — Quality & polish

1. **README accuracy + structure overhaul** (M)
   No H1/TOC in a 359-line file; the stale `~> 0.7.7` pin (README:135) steers users onto the VERIFY_NONE-default line; phantom `use_ssl: true` (README:310) is never read (TLS is derived at proxy.rb:138); `:username`/`:password`/`:cert`/`:key` and the `rack.backend`/`http.read_timeout` env keys are undocumented; the Todos/WARNING (README:354-359, :349-352) falsely claim streaming is broken/off though it's the tested default (proxy.rb:73).
   **Do:** add `# Rack::Proxy` H1 + TOC; fix the pin; remove `use_ssl`; document the missing options; delete the stale Todos/WARNING and rewrite the `:streaming`/webmock caveat truthfully (streaming works and defaults on; set `streaming: false` under webmock/vcr).

2. **Expose `:open_timeout`/`:write_timeout` + document the read_timeout deadline gap** (M)
   Only `read_timeout` is wired (proxy.rb:75,139,147,156); open/write default to 60s and can't be tightened, and `read_timeout` is per-read, so a trickling backend (reachable via the Host-header SSRF path) holds a thread indefinitely.
   **Do:** accept `:open_timeout`/`:write_timeout` (defaulting to `read_timeout`) on both paths + matching env overrides; rescue `Net::WriteTimeout` → 502; document that `read_timeout` is per-read, not a total deadline; offer an **opt-in** overall deadline (never default — it would break streaming/SSE).

3. **Cap response buffering with `:max_response_length`** (M)
   `HttpStreamingResponse#to_s` buffers unbounded into a `StringIO` (http_streaming_response.rb:44-46) and the `streaming: false` path (proxy.rb:170, README-recommended) reads the whole body into memory with no cap — remotely steerable via the Host-header backend fallback.
   **Do:** add `:max_response_length`, enforced in `#each`'s read loop and around the non-streaming read (abort + close → 502/413); optionally pre-check the backend `Content-Length`; document `#to_s` as a full-buffer, stream-consuming call.

4. **Fix the Rakefile + modernize gemspec packaging** (S)
   `Rake::TestTask` is defined inside the running `:test` task (Rakefile:6-12) and only runs via an `Array#each` mid-iteration fluke; the gemspec ships tests/CI via `git ls-files`, sets deprecated `test_files`, and lists executables from a nonexistent `bin/` (:17-19); reading VERSION loads the whole library (incl. the Net::HTTP patch) at build time.
   **Do:** top-level `Rake::TestTask.new(:test)` + `task default: :test`; move VERSION to `lib/rack/proxy/version.rb`; `s.files = Dir['lib/**/*.rb'] + %w[README.md LICENSE CHANGELOG.md]`; drop `test_files`/`executables`. Add a CI build-smoke that asserts `lib/rack/proxy.rb` is in the packaged gem.

5. **Relocate bundled examples out of the load path** (M)
   `lib/rack_proxy_examples/*.rb` run `Rails.application.config.middleware.use` and mutate ENV at require time (forward_host.rb:24, rack_php_proxy.rb:17,37) yet ship on the gem load path, so RBI/doc tooling crashes and a stray require silently installs a proxy; README:62 tells users to require them.
   **Do:** move to `examples/` (or guard the trailing calls with `if defined?(Rails)`), rework the README to treat them as copy-paste snippets, add a smoke test loading each against a minimal Rails stub.

6. **Set an honest Ruby floor + add `.ruby-version`** (S)
   gemspec:15 claims `>= 2.6` but tests use Ruby 3.0 endless-method syntax (rack_proxy_test.rb:131-133), so the floor is untestable; nothing records the 3.3.4 dev interpreter.
   **Do:** raise `required_ruby_version` to a tested floor (`>= 3.0` honest minimum, or `>= 3.1` to run on `ubuntu-latest`); pin `.ruby-version` to the interpreter in use; align the CI matrix; refresh `BUNDLED WITH`/`rake` in Gemfile.lock.

7. **Adopt Standard/RuboCop + `frozen_string_literal` pragmas** (M)
   No linter config; style spans eras (hashrockets, `Hash[mapped]` proxy.rb:38, `opts= {}` :65) and zero files carry `frozen_string_literal` (a warning source on Ruby 3.4+).
   **Do:** add minimal Standard (or RuboCop with `TargetRubyVersion` matching the floor) as a dev dep; run `--fix` once as a dedicated commit; add `# frozen_string_literal: true` to all `.rb` files; wire a lint + `bundler-audit` job into CI. Gives agents a machine-checkable style oracle.

8. **Migrate `:ssl_version` to `:min_version`/`:max_version`** (S)
   `http.ssl_version=` (proxy.rb:76,148,157) is the deprecated OpenSSL API and pins to an exact protocol — `ssl_version: :TLSv1_2` silently forbids TLS 1.3.
   **Do:** accept `:min_version`/`:max_version` → `Net::HTTP#min_version=`/`max_version=` on both paths; keep `:ssl_version` working with a deprecation warning; default to unpinned negotiation; update the README.

---

## P3 — Nice-to-have

1. **Opt-in credential + XFF stripping conveniences** (S) — Cookie/Authorization forward verbatim (proxy.rb:22-32) and inbound XFF is preserved with REMOTE_ADDR appended (:29-31); both are standard proxy behavior but there's no one-liner to harden edge deployments. **Do:** add opt-in `strip_credentials` and `replace_x_forwarded_for` options, documented in the SECURITY section.
2. **Add SimpleCov with branch coverage + a ratcheted floor** (S) — untested paths include the `#code` 204/205/304 branch (http_streaming_response.rb:23-27), the `REQUEST_URI` fallback, `basic_auth` wiring, and the `rack.backend`/`http.read_timeout` overrides. **Do:** start SimpleCov at the top of `test_helper.rb` (branch coverage, `add_filter '/test/'`), pin `minimum_coverage` to the post-hermetic baseline; no external upload service.
3. **Add `CONTRIBUTING.md` + record framework/test decisions** (S) — no CONTRIBUTING; release flow and the "keep test-unit / never add webmock/vcr" decisions are implicit. **Do:** document setup, the `with_webrick_proxy` requirement for new tests, the release process, a SemVer statement (consider cutting 1.0.0), and the framework decision.
4. **Add `.github` issue/PR templates** (S) — bug triage needs the streaming/non-streaming path and backend scheme up front (diverge at proxy.rb:143-166). **Do:** `ISSUE_TEMPLATE/bug_report.yml` (ruby/rack/rack-proxy versions, streaming true/false, backend scheme, minimal `config.ru`), a `PULL_REQUEST_TEMPLATE.md`, and `config.yml` routing security contact at `SECURITY.md`.
5. **Refresh LICENSE copyright line** (S) — LICENSE:3 reads 2013; project dates to 2010 with 2026 contributors. **Do:** optionally update to `2010-2026 Jacek Becela and contributors` (cosmetic; current line is legally fine).

---

## Making the repo safe for AI agents (the through-line)

The author's stated goal is served by a specific spine of items, sequenced so agents always have a trustworthy signal and can't silently regress the security defaults:

- **A deterministic green loop** — hermetic offline tests (P1-1) + a sane `rake test` (P2-4) + CI as ground truth (P1-2). Without this, agents "fix" correct code, loosen assertions, or add webmock and break streaming.
- **A written contract** — `CLAUDE.md`/`AGENTS.md` (P1-3) encoding the invariants, the `net_http_hacked` "do not clean up" warning, and the with-WEBrick test rule.
- **One source of truth for security-critical config** — deduped Net::HTTP setup (P1-4) so a TLS option can't land on one path only.
- **Documented trust boundaries** — the SECURITY section (P1-8) so agents scaffolding subclasses don't reproduce the open-proxy/credential-leak shapes the examples currently teach.

## Suggested execution order / milestones

- **Batch 1 — Reliable green loop (foundation PR set):** P1-1 hermetic suite → P2-4 Rakefile → P1-2 CI + dependabot → P1-3 `CLAUDE.md`/`AGENTS.md` → P2-6 Ruby floor/`.ruby-version`. *Lands a deterministic offline signal + CI before any behavior changes — the harness every later regression test depends on.*
- **Batch 2 — Security & correctness (P0):** all six P0 items + P1-4 config dedup, each shipping regression tests on the new harness. *The headline hardening pass.*
- **Batch 3 — Modernization & hardening:** P1-5 Fiber rewrite → P1-6 `ca_file` + TLS success test → P1-7 rack pin + `require "rack"` → P2-2 timeouts → P2-3 buffering cap → P2-8 min/max TLS version → P2-5 examples relocation.
- **Batch 4 — Docs, supply-chain & polish:** P1-8 SECURITY docs → P1-9 metadata/MFA/Trusted Publishing/CHANGELOG → P2-1 README overhaul → P2-7 linter + frozen literals → remaining P3 items.
