# frozen_string_literal: true

source 'https://rubygems.org'

# The Ruby floor is 3.1, the oldest version Open OnDemand's own CI tests.
# Several deps have released Ruby-3.2+-only versions; the pins below keep the
# lockfile installable on 3.1. Revisit them when that floor moves.

gem 'json'
gem 'mcp', '~> 1.11'
# Transitive dependency of fog-json. 1.20.0+ requires Ruby 3.2.
gem 'multi_json', '1.19.1'
gem 'ood_core', '~> 0.31'
# ood_core requires ostruct, which stopped being a default gem in Ruby 4.0.
gem 'ostruct'
gem 'puma'
gem 'rackup'
gem 'sinatra', '~> 4.2'

# public_suffix 7.0 requires Ruby 3.2 (transitive via json-schema/addressable).
gem 'public_suffix', '< 7'

group :development, :test do
  gem 'rake'
  gem 'rubocop'
end

group :test do
  # parallel 2.0+ requires Ruby 3.3 (transitive via rubocop).
  gem 'parallel', '< 2.0'
  # minitest 6 requires Ruby 3.2.
  gem 'minitest', '< 6'
  gem 'mocha'
  gem 'rack-test'
  # simplecov 1.0 requires Ruby 3.2+; 0.22 supports Ruby >= 2.5.
  gem 'simplecov', '~> 0.22', require: false
end
