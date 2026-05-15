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
Rails.application.config.middleware.use TrustingProxy,
  backend: 'https://self-signed.badssl.com',
  streaming: false,
  ssl_verify_none: true
