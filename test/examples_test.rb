require "test_helper"
require "rack/proxy"

# The examples are copy-paste snippets in examples/ — not shipped in the gem
# and not on the load path. They must still load cleanly outside a Rails app
# (no crash, no side effect: each only wires itself into the middleware stack
# when Rails is booted), because users copy them into arbitrary apps and the
# trailing Rails-guard has to stay correct.
class ExamplesTest < Test::Unit::TestCase
  EXAMPLES = {
    "forward_host"          => "ForwardHost",
    "rack_php_proxy"        => "RackPhpProxy",
    "trusting_proxy"        => "TrustingProxy",
    "example_service_proxy" => "ExampleServiceProxy"
  }.freeze

  EXAMPLES_DIR = File.expand_path("../examples", __dir__)

  def test_examples_are_safe_to_load_without_rails
    assert !defined?(Rails), "this test assumes Rails is not loaded"

    EXAMPLES.each do |file, class_name|
      assert_nothing_raised("loading #{file} outside Rails must not raise") do
        require File.join(EXAMPLES_DIR, file)
      end
      assert Object.const_defined?(class_name), "#{class_name} should be defined after loading #{file}"
      assert Object.const_get(class_name).ancestors.include?(Rack::Proxy),
        "#{class_name} should subclass Rack::Proxy"
    end
  end
end
