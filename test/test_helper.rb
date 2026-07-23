require "rubygems"
require "bundler/setup"

# Coverage is opt-in (COVERAGE=1) because simplecov lives only in the default
# Gemfile — the rack-2/rack-3 matrix gemfiles run the suite without it. The CI
# lint job runs with COVERAGE=1 and enforces the floor below; raise the floor
# as coverage improves, never lower it to make a change pass.
if ENV["COVERAGE"]
  begin
    require "simplecov"
  rescue LoadError
    abort "COVERAGE=1 needs simplecov, which lives only in the default Gemfile " \
          "(not in #{ENV["BUNDLE_GEMFILE"] || "the current gemfile"}). " \
          "Re-run without BUNDLE_GEMFILE, or unset COVERAGE."
  end
  SimpleCov.start do
    enable_coverage :branch
    skip "/test/"
    skip "/examples/"
  end
  # Ratchet: baseline was line 97.55 / branch 85.83 when introduced. The floor
  # sits ~1pp under that (lib/ is small: one line ~0.4pp, one branch ~0.8pp),
  # leaving a couple of lines of slack for platform deltas and deliberate
  # untested guards — raise it as coverage improves, never lower it.
  SimpleCov.minimum_coverage line: 96.5, branch: 84.5
end

require "test/unit"

require "rack"
require "rack/test"

require_relative "support/proxy_test_server"

Test::Unit::TestCase.class_eval do
  include Rack::Test::Methods
end
