# frozen_string_literal: true

###
# Open http://localhost:3000/test.php to trigger proxy
###
class RackPhpProxy < Rack::Proxy

  def perform_request(env)
    request = Rack::Request.new(env)
    if request.path =~ %r{\.php}
      env["HTTP_HOST"] = ENV["HTTP_HOST"] ? URI(ENV["HTTP_HOST"]).host : "localhost"
      ENV["PHP_PATH"] ||= '/manual/en/tutorial.firstpage.php'
       
      # Rails 3 & 4
      env["REQUEST_PATH"] = ENV["PHP_PATH"] || "/php/#{request.fullpath}"
      # Rails 5 and above
      env['PATH_INFO'] = ENV["PHP_PATH"] || "/php/#{request.fullpath}"

      env['content-length'] = nil
      
      super(env)
    else
      @app.call(env)
    end
  end

  def rewrite_response(triplet)
    status, headers, body = triplet
    
    # if you proxy depending on the backend, it appears that content-length isn't calculated correctly
    # resulting in only partial responses being sent to users
    # you can remove it or recalculate it here
    headers["content-length"] = nil

    triplet
  end
end

# Only wire into the middleware stack when running inside a booted Rails app.
if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
  Rails.application.config.middleware.use RackPhpProxy, backend: 'http://php.net', streaming: false
end
