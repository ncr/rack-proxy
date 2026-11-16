require "test_helper"
require "rack/proxy"
require "rack/lint"

class RequestBodyStreamTest < Test::Unit::TestCase
  {all: nil, bounded: 7}.each do |name, length|
    define_method("test_#{name}_read_without_buffer_preserves_rack_input_contract") do
      app = lambda do |env|
        stream = Rack::Proxy.const_get(:RequestBodyStream).new(env.fetch("rack.input"), 7)
        payload = length ? stream.read(length) : stream.read
        [200, {}, [payload]]
      end
      env = Rack::MockRequest.env_for("/", method: "POST", input: "payload")
      status, _headers, body = Rack::Lint.new(app).call(env)
      chunks = []
      body.each { |chunk| chunks << chunk }
      body.close

      assert_equal 200, status
      assert_equal ["payload"], chunks
    end
  end
end
