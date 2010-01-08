require "test_helper"
require "rack/http_streaming_response"

class HttpStreamingResponseTest < Test::Unit::TestCase
  
  def test_streaming
    host, req = "trix.pl", Net::HTTP::Get.new("/")
    
    response = Rack::HttpStreamingResponse.new(req, host)
    
    # Response status
    assert response.status == "200"
    
    # Headers
    headers = response.headers
    
    assert headers.size > 0
    assert headers["content-type"] == "text/html"
    assert headers["CoNtEnT-TyPe"] == "text/html"
    assert headers["content-length"].to_i > 0
    
    # Body
    chunks = []
    response.body.each do |chunk|
      chunks << chunk
    end
    
    assert chunks.size > 0
    chunks.each do |chunk|
      assert chunk.is_a?(String)
    end
  end
  
end

