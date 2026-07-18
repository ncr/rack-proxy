# frozen_string_literal: true

class ForwardHost < Rack::Proxy
  def rewrite_env(env)
    env["HTTP_HOST"] = "example.com"
    env
  end

  def rewrite_response(triplet)
    _, headers, _ = triplet

    # example of inserting an additional header
    headers["X-Foo"] = "Bar"

    # if you rewrite env, it appears that content-length isn't calculated correctly
    # resulting in only partial responses being sent to users
    # you can remove it or recalculate it here
    headers["content-length"] = nil

    triplet
  end
end

# Only wire into the middleware stack when running inside a booted Rails app.
if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
  Rails.application.config.middleware.use ForwardHost, backend: "http://example.com", streaming: false
end
