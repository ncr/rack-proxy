require "test_helper"
require "rack/proxy"
require "rack/lint"

class RequestBodyStreamTest < Test::Unit::TestCase
  LENGTH = 7

  def test_all_read_without_buffer_preserves_rack_input_contract
    assert_read_without_buffer_preserves_rack_input_contract(nil)
  end

  def test_bounded_read_without_buffer_preserves_rack_input_contract
    assert_read_without_buffer_preserves_rack_input_contract(LENGTH)
  end

  def assert_read_without_buffer_preserves_rack_input_contract(length)
    app = lambda do |env|
      stream = Rack::Proxy.const_get(:RequestBodyStream).new(env.fetch("rack.input"), LENGTH)
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
