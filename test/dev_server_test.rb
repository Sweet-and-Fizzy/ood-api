# frozen_string_literal: true

require 'json'
require 'open3'
require 'rbconfig'
require_relative 'test_helper'

# The development server has no Apache in front of it and nothing
# authenticates its requests, so the Host checks that a PUN does not need
# are what keep a page on another site from reaching it through the
# developer's browser. They are decided when the app loads, so this runs
# the app in a process of its own, without the variable Passenger sets.
class DevServerTest < Minitest::Test
  SCRIPT = <<~RUBY
    require 'json'
    require 'rack/mock'
    require_relative 'app/api'
    require_relative 'app/mcp_server'
    list = JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/list', params: {})
    result = ['localhost:9292', 'evil.example:9292'].to_h do |host|
      health = OodApi::App.call(Rack::MockRequest.env_for("http://\#{host}/health", 'HTTP_HOST' => host)).first
      mcp = OodApi.mcp_rack_app.call(
        Rack::MockRequest.env_for("http://\#{host}/", method: 'POST', input: list, 'HTTP_HOST' => host,
                                  'CONTENT_TYPE' => 'application/json',
                                  'HTTP_ACCEPT' => 'application/json, text/event-stream')
      ).first
      [host, { health: health, mcp: mcp }]
    end
    puts JSON.generate(result)
  RUBY

  def statuses(extra_env)
    env = { 'RACK_ENV' => 'development', 'PASSENGER_BASE_URI' => nil,
            'OOD_API_CONFIG_ROOT' => ENV.fetch('OOD_API_CONFIG_ROOT'),
            'OOD_CONFIG_D_DIRECTORY' => ENV.fetch('OOD_CONFIG_D_DIRECTORY') }.merge(extra_env)
    out, err, status = Open3.capture3(env, RbConfig.ruby, '-e', SCRIPT, chdir: File.expand_path('..', __dir__))
    assert status.success?, err
    JSON.parse(out.lines.last)
  end

  def test_the_development_server_answers_only_to_a_loopback_host
    result = statuses({})

    assert_equal({ 'health' => 200, 'mcp' => 200 }, result['localhost:9292'])
    assert_equal 403, result['evil.example:9292']['health']
    assert_equal 403, result['evil.example:9292']['mcp']
  end

  # The check must not depend on the environment the server was started in.
  def test_the_check_holds_whatever_environment_the_server_runs_as
    ['production', 'test'].each do |environment|
      result = statuses('RACK_ENV' => environment)

      assert_equal 200, result['localhost:9292']['health'], environment
      assert_equal 403, result['evil.example:9292']['health'], environment
      assert_equal 403, result['evil.example:9292']['mcp'], environment
    end
  end

  def test_in_a_pun_any_host_is_served
    result = statuses('PASSENGER_BASE_URI' => '/pun/sys/ood-api', 'RACK_ENV' => 'production')

    assert_equal({ 'health' => 200, 'mcp' => 200 }, result['evil.example:9292'])
  end
end
