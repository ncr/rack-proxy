require "net_http_hacked"
require "rack/http_streaming_response"

module Rack

  # Subclass and bring your own #rewrite_request and #rewrite_response
  class Proxy
    VERSION = "0.3.7"
    
    def call(env)
      rewrite_response(perform_request(rewrite_env(env)))
    end

    # Return modified env
    def rewrite_env(env)
      env
    end
    
    # Return a rack triplet [status, headers, body]
    def rewrite_response(triplet)
      triplet
    end

    protected

    def perform_request(env)
      source_request = Rack::Request.new(env)
      
      # Initialize request
      target_request = Net::HTTP.const_get(source_request.request_method.capitalize).new(source_request.fullpath)

      # Setup headers
      target_request.initialize_http_header(extract_http_request_headers(source_request.env))

      # Setup body
      if target_request.request_body_permitted? && source_request.body
        target_request.body_stream    = source_request.body
        target_request.content_length = source_request.content_length
        target_request.content_type   = source_request.content_type if source_request.content_type
      end
      
      # Create a streaming response (the actual network communication is deferred, a.k.a. streamed)
      target_response = HttpStreamingResponse.new(target_request, source_request.host, source_request.port)

      target_response.use_ssl = "https" == source_request.scheme
      
      [target_response.status, target_response.headers, target_response.body]
    end
    
    def extract_http_request_headers(env)
      headers = env.reject do |k, v|
        !(/^HTTP_[A-Z_]+$/ === k) || v.nil?
      end.map do |k, v|
        [reconstruct_header_name(k), v]
      end.inject(Utils::HeaderHash.new) do |hash, k_v|
        k, v = k_v
        hash[k] = v
        hash
      end

      x_forwarded_for = (headers["X-Forwarded-For"].to_s.split(/, +/) << env["REMOTE_ADDR"]).join(", ")

      headers.merge!("X-Forwarded-For" =>  x_forwarded_for)
    end

    def reconstruct_header_name(name)
      name.sub(/^HTTP_/, "").gsub("_", "-")
    end

  end

end
