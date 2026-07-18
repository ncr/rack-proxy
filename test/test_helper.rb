require "rubygems"
require "bundler/setup"

# Coverage is opt-in (COVERAGE=1) because simplecov lives only in the default
# Gemfile — the rack-2/rack-3 matrix gemfiles run the suite without it. The CI
# lint job runs with COVERAGE=1 and enforces the floor below; raise the floor
# as coverage improves, never lower it to make a change pass.
if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    skip "/test/"
    skip "/examples/"
  end
  # Ratchet: baseline was line 97.55 / branch 85.83 when introduced.
  SimpleCov.minimum_coverage line: 97, branch: 85
end

require "test/unit"

require "rack"
require "rack/test"

require_relative "support/proxy_test_server"

Test::Unit::TestCase.class_eval do
  include Rack::Test::Methods
end
