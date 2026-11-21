# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/origin_check'

class OriginCheckTest < Minitest::Test
  def teardown
    ENV.delete('OOD_API_ALLOWED_ORIGINS')
  end

  def cross_site?(env)
    OodApi::OriginCheck.cross_site?({ 'HTTP_HOST' => 'ood.example.edu' }.merge(env))
  end

  def test_non_browser_clients_send_neither_header_and_pass
    refute cross_site?({})
  end

  def test_same_origin_passes
    refute cross_site?('HTTP_ORIGIN' => 'https://ood.example.edu')
    refute cross_site?('HTTP_ORIGIN' => 'https://OOD.example.edu:443')
    refute cross_site?('HTTP_SEC_FETCH_SITE' => 'same-origin')
    refute cross_site?('HTTP_SEC_FETCH_SITE' => 'none')
  end

  def test_other_origins_are_refused
    assert cross_site?('HTTP_ORIGIN' => 'https://evil.example')
    assert cross_site?('HTTP_ORIGIN' => 'https://ood.example.edu.evil.example')
    assert cross_site?('HTTP_ORIGIN' => 'https://ood.example.edu:8443')
    assert cross_site?('HTTP_ORIGIN' => 'null')
    assert cross_site?('HTTP_ORIGIN' => 'not a url')
  end

  # A sibling subdomain shares the site but not the origin, and the session
  # cookie is still sent.
  def test_same_site_and_cross_site_fetches_are_refused
    assert cross_site?('HTTP_SEC_FETCH_SITE' => 'cross-site')
    assert cross_site?('HTTP_SEC_FETCH_SITE' => 'same-site')
  end

  def test_origin_wins_over_sec_fetch_site
    assert cross_site?('HTTP_ORIGIN' => 'https://evil.example', 'HTTP_SEC_FETCH_SITE' => 'same-origin')
  end

  def test_forwarded_host_counts_as_this_host
    env = { 'HTTP_HOST' => 'internal:8080', 'HTTP_X_FORWARDED_HOST' => 'ood.example.edu',
            'HTTP_ORIGIN' => 'https://ood.example.edu' }
    refute OodApi::OriginCheck.cross_site?(env)
  end

  def test_site_can_allow_additional_origins
    ENV['OOD_API_ALLOWED_ORIGINS'] = 'https://portal.example.edu/, https://other.example.edu'

    refute cross_site?('HTTP_ORIGIN' => 'https://portal.example.edu')
    assert cross_site?('HTTP_ORIGIN' => 'https://evil.example')
  end
end
