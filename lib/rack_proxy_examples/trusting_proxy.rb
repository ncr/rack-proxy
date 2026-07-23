# frozen_string_literal: true

class TrustingProxy < Rack::Proxy

  def rewrite_env(env)
    env["HTTP_HOST"] = "self-signed.badssl.com"
    env
  end

  def rewrite_response(triplet)
    status, headers, body = triplet

    # if you rewrite env, it appears that content-length isn't calculated correctly
    # resulting in only partial responses being sent to users
    # you can remove it or recalculate it here
    headers["content-length"] = nil

    triplet
  end

end

# Pass ssl_verify_none: true to skip TLS certificate verification.
# Only wire into the middleware stack when running inside a booted Rails app.
if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
  Rails.application.config.middleware.use TrustingProxy,
    backend: 'https://self-signed.badssl.com',
    streaming: false,
    ssl_verify_none: true
end
