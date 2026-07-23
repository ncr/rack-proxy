# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "rack/proxy/version"

Gem::Specification.new do |s|
  s.name        = "rack-proxy"
  s.version     = Rack::Proxy::VERSION
  s.platform    = Gem::Platform::RUBY
  s.license     = 'MIT'
  s.authors     = ["Jacek Becela"]
  s.email       = ["jacek.becela@gmail.com"]
  s.homepage    = "https://github.com/ncr/rack-proxy"
  s.summary     = %q{A request/response rewriting HTTP proxy. A Rack app.}
  s.description = %q{A Rack app that provides request/response rewriting proxy capabilities with streaming.}
  s.required_ruby_version = ">= 3.0"

  s.files = Dir["lib/**/*.rb"] + %w[README.md LICENSE rack-proxy.gemspec]
  s.require_paths = ["lib"]

  s.add_dependency("rack")
  s.add_development_dependency("rack-test")
  s.add_development_dependency("test-unit")
  s.add_development_dependency("webrick")
end
