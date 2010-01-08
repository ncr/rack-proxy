require "net_http_hacked"

module Rack

  # Wraps the hacked net/http in a Rack way.
  class HttpStreamingResponse
    def initialize(request, host, port = nil)
      @request, @host, @port = request, host, port
    end
    
    def status
      response.code.to_i
    end
    
    def headers
      h = Utils::HeaderHash.new
      
      response.each_header do |k, v|
        h[k] = v
      end
      
      h
    end
    
    def body
      self
    end

    def each(&block)
      response.read_body(&block)
    ensure
      session.end_request_hacked
    end
        
    protected
    
    # Net::HTTPResponse
    def response
      @response ||= session.begin_request_hacked(@request)
    end
    
    # Net::HTTP
    def session
      @session ||= Net::HTTP.start(@host, @port)
    end
    
  end

end
