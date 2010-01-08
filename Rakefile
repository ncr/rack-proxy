require "rake/testtask"

task :test do
  Rake::TestTask.new do |t|
    t.libs << "test"
    t.test_files = FileList['test/*_test.rb']
    t.verbose = true
  end
end

task :default => :test

begin
  require 'jeweler'
  Jeweler::Tasks.new do |gem|
    gem.name = "rack-proxy"
    gem.summary = "A request/response rewriting HTTP proxy. A Rack app."
    gem.description = "A Rack app that provides request/response rewriting proxy capabilities with streaming."
    gem.email = "jacek.becela@gmail.com"
    gem.homepage = "http://github.com/ncr/rack-proxy"
    gem.authors = ["Jacek Becela"]
    gem.add_dependency "rack"
    gem.add_development_dependency "rack-test"
  end
rescue LoadError
  puts "Jeweler not available. Install it with: gem install jeweler"
end
