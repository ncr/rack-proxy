require "test_helper"
require "rack/proxy"

# The bundled examples ship on the gem load path, so they must be safe to
# require outside a Rails app: no crash and no side effect (they only wire
# themselves into the middleware stack when Rails is booted). This guards
# doc/RBI tooling and stray requires.
class ExamplesTest < Test::Unit::TestCase
  EXAMPLES = {
    "rack_proxy_examples/forward_host"          => "ForwardHost",
    "rack_proxy_examples/rack_php_proxy"        => "RackPhpProxy",
    "rack_proxy_examples/trusting_proxy"        => "TrustingProxy",
    "rack_proxy_examples/example_service_proxy" => "ExampleServiceProxy"
  }.freeze

  def test_examples_are_safe_to_require_without_rails
    assert !defined?(Rails), "this test assumes Rails is not loaded"

    EXAMPLES.each do |path, class_name|
      assert_nothing_raised("requiring #{path} outside Rails must not raise") do
        require path
      end
      assert Object.const_defined?(class_name), "#{class_name} should be defined after requiring #{path}"
      assert Object.const_get(class_name).ancestors.include?(Rack::Proxy),
        "#{class_name} should subclass Rack::Proxy"
    end
  end
end
