# Contributing to rack-proxy

Thanks for helping improve rack-proxy. It is a small, security-sensitive library,
so the bar is safe defaults, no surprises, and no regressions of the security
behavior documented in [`CLAUDE.md`](CLAUDE.md).

## Getting started

```sh
bundle install
bundle exec rake test             # full suite, fully OFFLINE, ~2-3s
COVERAGE=1 bundle exec rake test  # same, plus a SimpleCov report in coverage/
bundle exec standardrb            # style check (CI-blocking); --fix to autofix
bundle exec bundler-audit check --update  # dependency advisory audit
```

Coverage has a ratcheted floor (line 96.5 / branch 84.5, enforced by the CI
lint job) — raise it as coverage improves; never lower it to make a change pass.

The default suite never touches the network. To additionally run the real-internet
smoke tests:

```sh
LIVE=1 bundle exec rake test
```

To run against a specific Rack major (CI runs both):

```sh
BUNDLE_GEMFILE=gemfiles/rack_3.gemfile bundle exec rake test
BUNDLE_GEMFILE=gemfiles/rack_2.gemfile bundle exec rake test
```

## Ground rules

- **Read [`CLAUDE.md`](CLAUDE.md) first.** It lists the security invariants (each
  mapped to its guarding test) and the traps.
- **Tests must be offline.** Use `with_webrick_proxy` (in
  `test/rack_proxy_test.rb`) or `ProxyTestServer` (in
  `test/support/proxy_test_server.rb`). Do not add live-host tests; put anything
  that genuinely needs the internet behind `ENV["LIVE"]` in
  `test/live_smoke_test.rb`.
- **Do not add `webmock` or `vcr`** — tests must exercise real `Net::HTTP`
  traffic; request-stubbing layers would make the streaming tests meaningless.
- **Do not "simplify" the Fiber plumbing in `HttpStreamingResponse`.** The
  `max_retries = 0`, the `StreamAborted` unwind class, and the forced
  `decode_content = false` are load-bearing (see the trap list in
  [`CLAUDE.md`](CLAUDE.md)). The old `net_http_hacked.rb` monkey-patch was
  deleted in 1.0 — do not reintroduce it.
- **Keep the test framework as `test-unit`.**
- New behavior needs a regression test; bug fixes should add a test that fails
  before the fix.

## Pull requests

1. Fork and branch from `master`.
2. Make the change with tests; keep `bundle exec rake test` green on Rack 2 and 3,
   and `bundle exec standardrb` clean.
3. Add a `CHANGELOG.md` entry under `[Unreleased]`.
4. Open the PR describing the streaming/non-streaming paths affected and the
   backend scheme, if relevant.

## Versioning & releases (maintainers)

From 1.0.0 on, this project follows [SemVer](https://semver.org) strictly:
breaking changes (including dropping a Ruby/Rack version or changing a security
default) ship only in majors; deprecations get at least one minor with a
runtime warning where practical.

To cut a release:

1. Bump `lib/rack/proxy/version.rb`.
2. **Run `bundle install` and commit the updated `Gemfile.lock` in the same
   commit.** The gem is a path dependency in the lockfile, so a version bump
   leaves the lock stale; CI runs `bundle install` in frozen/deployment mode
   (`bundler-cache: true`) and hard-fails on the mismatch otherwise — including
   in the tag-triggered release workflow.
3. Move the `[Unreleased]` CHANGELOG section under the new version and add its
   compare link at the bottom of the file.
4. Merge, then tag `vX.Y.Z` and push the tag. `.github/workflows/release.yml`
   verifies the tag equals `Rack::Proxy::VERSION`, runs the suite, and
   publishes to rubygems.org via Trusted Publishing (OIDC, no long-lived
   credentials).

## Reporting security issues

Please do **not** open a public issue. See [`SECURITY.md`](SECURITY.md).
