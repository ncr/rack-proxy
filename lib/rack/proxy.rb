require "net_http_hacked"
require "rack/http_streaming_response"

module Rack

  # Subclass and bring your own #rewrite_request and #rewrite_response
  class Proxy
    def call(env)
      rewrite_response(perform_request(rewrite_request(Rack::Request.new(env))))
    end

    # Return an instance of Rack::Request
    def rewrite_request(req)
      req
    end
    
    # Return a rack triplet [status, headers, body]
    def rewrite_response(triplet)
      triplet
    end

    protected

    def perform_request(req)
      # Initialize request
      http_request = Net::HTTP.const_get(req.request_method.capitalize).new(req.fullpath)

      # Setup headers
      http_request.initialize_http_header(http_request_headers(req))

      # Setup body
      if http_request.request_body_permitted? && req.body
        http_request.body_stream = req.body
      end
      
      # Create a streaming response (the actual network communication is deferred, a.k.a. streamed)
      http_response = HttpStreamingResponse.new(http_request, req.host, req.port)
      
      [http_response.status, http_response.headers, http_response.body]
    end
    
    def http_request_headers(req)
      headers = req.env.reject do |k, v|
        !(/^HTTP_[A-Z_]+$/ === k)
      end.map do |k, v|
        [k.sub(/^HTTP_/, ""), v]
      end.inject(Utils::HeaderHash.new) do |hash, k_v|
        k, v = k_v
        hash[k] = v
        hash
      end

      x_forwarded_for = (headers["X-Forwarded-For"].to_s.split(/, +/) << req.env["REMOTE_ADDR"]).join(", ")

      headers.merge!("X-Forwarded-For" =>  x_forwarded_for)
    end

  end

end
