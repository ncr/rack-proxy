# Security Policy

`rack-proxy` is a request/response-rewriting HTTP proxy. Because it forwards
attacker-influenced requests to a backend and relays the backend's response, how
you configure and subclass it has direct security consequences. Please read the
threat model below alongside the "Security considerations" section of the README.

## Supported versions

Security fixes are released for the latest major series. Older supported
series receive critical fixes only during their transition period — please
upgrade to `2.x`.

| Version | Supported |
| ------- | --------- |
| 2.0.x   | ✅        |
| 1.0.x   | critical fixes only |
| 0.8.x   | critical fixes only |
| < 0.8   | ❌        |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through GitHub's **Report a vulnerability** button under the
repository's *Security* tab (Private Vulnerability Reporting). If that is
unavailable to you, email the maintainer at **jacek.becela@gmail.com** with
`[rack-proxy security]` in the subject.

Please include:

- the rack-proxy, Rack, and Ruby versions,
- whether you run in streaming (`streaming: true`, the default) or non-streaming mode,
- a minimal `config.ru` / subclass that reproduces the issue,
- the impact you observed.

We aim to acknowledge a report within **5 business days** and to agree on a
disclosure timeline from there. We are grateful for responsible disclosure and
will credit reporters who want it.

## Scope

In scope: defects in the library itself — for example, credentials or hop-by-hop
headers being forwarded when they should not be, request/response smuggling,
verification defaults that are weaker than documented, or a crash/`500` where a
`4xx`/`5xx` mapping is expected.

Out of scope: insecure **configuration or subclassing** of the library. Since
1.0, deriving the backend from the client-controlled `Host` header requires an
explicit `allow_dynamic_backend: true`; opting in without a `backend_allowed?`
allowlist is an SSRF/open-proxy risk that is the deployer's responsibility —
see the README "Security considerations". If the documentation is what led you
astray, that is in scope: tell us and we will fix the docs.
