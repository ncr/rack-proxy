source "https://rubygems.org"

gem "rake"

# Specify your gem's dependencies in rack-proxy.gemspec
gemspec

# Dev-only tooling, deliberately NOT in the gemspec (and absent from
# gemfiles/rack_*.gemfile) so the CI test matrix stays lean. The CI lint job
# uses this Gemfile; SimpleCov only loads when COVERAGE=1 is set.
group :development do
  gem "simplecov", require: false
  gem "standard", require: false
  gem "bundler-audit", require: false
end
