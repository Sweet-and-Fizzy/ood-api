# frozen_string_literal: true

source 'https://rubygems.org'

# This app supports OOD 3.x (Ruby 3.0/3.1) and 4.x (Ruby 3.3). Several deps
# have released Ruby-3.2+-only versions; the pins below keep the lockfile
# installable on Ruby 3.0. Revisit them if the OOD 3.0/3.1 floor is dropped.

gem 'json'
gem 'mcp'
# Transitive dependency of mcp via json_schemer. Pinned only because 4.1.2 has
# no prebuilt darwin binary, so it compiles locally and picks up the host
# toolchain — which breaks a Rosetta (x86_64 Ruby on arm64 Mac) dev setup.
# Nothing here depends on 4.1.2; lift the pin once a prebuilt one lands.
gem 'bigdecimal', '4.1.1'
# Transitive dependency of fog-json. 1.20.0+ requires Ruby 3.2, which would
# drop OOD 3.x sites still on Ruby 3.0 — the floor CI enforces. Lift this pin
# only when that floor moves.
gem 'multi_json', '1.19.1'
gem 'ood_core', '~> 0.24'
gem 'puma'
gem 'rackup'
gem 'sinatra', '~> 3.0'

# excon 1.2.6+ requires Ruby 3.1 (transitive via ood_core).
gem 'excon', '< 1.2.6'
# public_suffix 7.0 requires Ruby 3.2 (transitive via json-schema/addressable).
gem 'public_suffix', '< 7'

group :development, :test do
  gem 'rake'
  gem 'rubocop'
end

group :test do
  # minitest 5.26.2+ requires Ruby 3.1.
  gem 'minitest', '< 5.26.2'
  gem 'mocha'
  gem 'rack-test'
  # simplecov 1.0 requires Ruby 3.2+; 0.22 supports Ruby >= 2.5.
  gem 'simplecov', '~> 0.22', require: false
end
