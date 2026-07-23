## What does this change, and why?

<!-- A sentence or two. Link the issue if there is one. -->

## Checklist

Please read [`CLAUDE.md`](../blob/master/CLAUDE.md) (invariants + traps) and
[`CONTRIBUTING.md`](../blob/master/CONTRIBUTING.md) first.

- [ ] `bundle exec rake test` is green on Rack 2 and Rack 3
      (`BUNDLE_GEMFILE=gemfiles/rack_2.gemfile bundle exec rake test`, same for `rack_3`)
- [ ] New behavior has a regression test; bug fixes add a test that fails before the fix
- [ ] Tests are offline (use `with_webrick_proxy` / `ProxyTestServer` — no live hosts, no webmock/vcr)
- [ ] Behavior changes have a `CHANGELOG.md` entry under `[Unreleased]`
- [ ] No security invariant regressed (VERIFY_PEER default, 502-never-raise,
      hop-by-hop stripping, no-retry streaming — see `CLAUDE.md`)
