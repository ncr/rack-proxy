module Rack

  # Subclass and bring your own #rewrite_request and #rewrite_response
  class Proxy
    def call(env)
      req = Rack::Request.new(env)
      res = rewrite_response(perform_request(rewrite_request(req)))
      [res.status, res.header, res.body]
    end

    def perform_request(req)
      raise "lolz no codes"
    end

    def rewrite_request(req) # or not
      req
    end
    
    def rewrite_response(res) # or not
      res
    end
  end

end
