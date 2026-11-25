# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/files'

class HandlersFilesFindTest < Minitest::Test
  def setup
    @dir = File.join(Dir.tmpdir, "ood-find-#{Process.pid}-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(File.join(@dir, 'project/logs'))
    FileUtils.touch(File.join(@dir, 'project/logs/growth-13.out'))
    FileUtils.touch(File.join(@dir, 'project/logs/fit-14.out'))
    FileUtils.touch(File.join(@dir, 'project/analyse.py'))
    FileUtils.touch(File.join(@dir, 'top.out'))
  end

  def teardown
    FileUtils.chmod_R(0o700, @dir) if Dir.exist?(@dir)
    FileUtils.rm_rf(@dir)
  end

  def names(result)
    result[:matches].map { |entry| entry.path.to_s.delete_prefix("#{@dir}/") }.sort
  end

  def test_it_finds_matching_names_in_every_subdirectory
    result = Handlers::Files.find(path: @dir, name: '*.out')

    assert_equal ['project/logs/fit-14.out', 'project/logs/growth-13.out', 'top.out'], names(result)
    refute result[:truncated]
    assert_equal 0, result[:skipped]
  end

  def test_a_link_to_a_directory_is_reported_but_not_followed
    outside = File.join(@dir, '..', "ood-find-outside-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(outside)
    FileUtils.touch(File.join(outside, 'hidden.out'))
    File.symlink(outside, File.join(@dir, 'linked.out'))

    result = Handlers::Files.find(path: @dir, name: '*.out')

    assert_includes names(result), 'linked.out'
    refute(names(result).any? { |name| name.include?('hidden.out') })
  ensure
    FileUtils.rm_rf(outside)
  end

  def test_a_directory_that_cannot_be_listed_is_skipped_and_counted
    skip 'root can list any directory' if Process.uid.zero?
    FileUtils.chmod(0o000, File.join(@dir, 'project/logs'))

    result = Handlers::Files.find(path: @dir, name: '*.out')

    assert_equal ['top.out'], names(result)
    assert_equal 1, result[:skipped]
  end

  def test_a_starting_directory_that_is_refused_is_an_error
    assert_raises(Handlers::Error) { Handlers::Files.find(path: '/etc/ood-find-does-not-exist', name: '*') }
  end

  def test_a_pattern_with_a_slash_is_refused
    assert_raises(Handlers::ValidationError) { Handlers::Files.find(path: @dir, name: 'logs/*.out') }
    assert_raises(Handlers::ValidationError) { Handlers::Files.find(path: @dir, name: ' ') }
  end

  def test_it_stops_at_the_result_limit_and_says_so
    (Handlers::Files::FIND_MAX_RESULTS + 5).times { |i| FileUtils.touch(File.join(@dir, "many-#{i}.txt")) }

    result = Handlers::Files.find(path: @dir, name: 'many-*')

    assert_equal Handlers::Files::FIND_MAX_RESULTS, result[:matches].size
    assert result[:truncated]
  end

  def test_it_stops_at_the_depth_limit_and_says_so
    deep = File.join(@dir, *Array.new(Handlers::Files::FIND_MAX_DEPTH + 2) { |i| "d#{i}" })
    FileUtils.mkdir_p(deep)
    FileUtils.touch(File.join(deep, 'bottom.out'))

    result = Handlers::Files.find(path: @dir, name: 'bottom.out')

    assert_empty result[:matches]
    assert result[:truncated]
  end
end
