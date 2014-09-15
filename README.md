A request/response rewriting HTTP proxy. A Rack app.
Subclass `Rack::Proxy` and provide your `rewrite_env` and `rewrite_response` methods.


## Example

```ruby
class Foo < Rack::Proxy

  def rewrite_env(env)
    env["HTTP_HOST"] = "example.com"

    env
  end

  def rewrite_response(triplet)
    status, headers, body = triplet

    headers["X-Foo"] = "Bar"

    triplet
  end

end
```

### Disable SSL session verification when proxying a server with e.g. self-signed SSL certs

```ruby
class TrustingProxy < Rack::Proxy

  def rewrite_env(env)
    env["rack.ssl_verify_none"] = true

    env
  end

end
```

The same can be achieved for *all* requests going through the `Rack::Proxy` instance by using

```ruby
Rack::Proxy.new(ssl_verify_none: true)
```

See tests for more examples.

## WARNING

Doesn't work with fakeweb/webmock. Both libraries monkey-patch net/http code.

## Todos

* Make the docs up to date with the current use case for this code: everything except streaming which involved a rather ugly monkey patch and only worked in 1.8, but does not work now.
