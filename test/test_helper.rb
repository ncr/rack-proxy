require "rubygems"
require "bundler/setup"
require "test/unit"

require "rack"
require "rack/test"

require_relative "support/proxy_test_server"

Test::Unit::TestCase.class_eval do
  include Rack::Test::Methods
end
