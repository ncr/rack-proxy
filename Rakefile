require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs = %w[lib test]
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = true
  t.verbose = true
end

task default: :test

# Lint tasks (rake standard / standard:fix). Guarded: standard lives only in
# the default Gemfile, not in the gemfiles/rack_*.gemfile CI matrix legs.
begin
  require "standard/rake"
rescue LoadError
end
