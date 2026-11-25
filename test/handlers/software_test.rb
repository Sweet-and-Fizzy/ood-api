# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/software'

class HandlersSoftwareTest < Minitest::Test
  include TestHelpers

  SPIDER = {
    'python'   => {
      '/apps/lmod/python/3.11.9.lua' => { 'Version' => '3.11.9', 'parentAA' => [['gcc/12.3.0']] },
      '/apps/lmod/python/3.12.4.lua' => { 'Version' => '3.12.4', 'parentAA' => [['gcc/12.3.0'], ['intel/2024.1']] },
      '/apps/lmod/python/2.7.18.lua' => { 'Version' => '2.7.18', 'hidden' => true }
    },
    'py-torch' => {
      '/apps/lmod/py-torch/2.3.1.lua' => { 'Version' => '2.3.1', 'parentAA' => [['gcc/12.3.0', 'cuda/12.4']] }
    },
    'gcc'      => { '/apps/lmod/gcc/12.3.0.lua' => { 'Version' => '12.3.0' } }
  }.freeze

  def setup
    @dir = Dir.mktmpdir('ood-modules')
    File.write(File.join(@dir, 'hpc.json'), JSON.generate(SPIDER))
    File.write(File.join(@dir, 'gpu.json'), JSON.generate('cuda' => { '/x' => { 'Version' => '12.4' } }))
    @saved = ENV.fetch('OOD_MODULE_FILE_DIR', nil)
    ENV['OOD_MODULE_FILE_DIR'] = @dir
    @clusters = [mock_cluster(id: 'hpc'), mock_cluster(id: 'gpu')]
  end

  def teardown
    @saved ? ENV['OOD_MODULE_FILE_DIR'] = @saved : ENV.delete('OOD_MODULE_FILE_DIR')
    FileUtils.rm_rf(@dir)
  end

  def test_matching_modules_come_with_versions_newest_first_and_what_to_load_first
    result = Handlers::Software.find(clusters: @clusters, name: 'PY')

    assert_equal ['py-torch', 'python'], result[:modules].map(&:name)
    python = result[:modules].last
    assert_equal ['3.12.4', '3.11.9'], python.versions.map(&:version), 'hidden 2.7.18 is left out'
    assert_equal [['gcc/12.3.0'], ['intel/2024.1']], python.versions.first.prerequisites
    assert_equal [['gcc/12.3.0', 'cuda/12.4']], result[:modules].first.versions.first.prerequisites
  end

  def test_names_match_without_case_or_punctuation
    ['pytorch', 'PyTorch', 'py_torch'].each do |asked|
      assert_equal ['py-torch'], Handlers::Software.find(clusters: @clusters, name: asked)[:modules].map(&:name), asked
    end
  end

  def test_one_cluster_can_be_asked_about
    assert_equal ['cuda'], Handlers::Software.find(clusters: @clusters, cluster_id: 'gpu')[:modules].map(&:name)
    assert_raises(Handlers::NotFoundError) { Handlers::Software.find(clusters: @clusters, cluster_id: 'nope') }
  end

  def test_a_cluster_with_no_or_broken_file_lists_nothing
    File.write(File.join(@dir, 'gpu.json'), '{not json')
    @clusters << mock_cluster(id: 'other')

    assert_equal ['gcc', 'py-torch', 'python'], Handlers::Software.find(clusters: @clusters)[:modules].map(&:name)
  end

  def test_names_past_the_limit_are_counted
    many = (1..(Handlers::Software::NAME_LIMIT + 3)).to_h { |i| ["mod#{i}", { '/m' => { 'Version' => '1' } }] }
    File.write(File.join(@dir, 'hpc.json'), JSON.generate(many))

    result = Handlers::Software.find(clusters: @clusters, name: 'mod')
    assert_equal Handlers::Software::NAME_LIMIT, result[:modules].size
    assert_equal 3, result[:more]
  end

  def test_a_site_without_a_module_list_is_told_so
    ENV.delete('OOD_MODULE_FILE_DIR')
    OodApi::SiteConfig.stubs(:module_file_dir).returns(nil)

    error = assert_raises(Handlers::NotSupportedError) { Handlers::Software.find(clusters: @clusters) }
    assert_match(/does not publish a list of its software modules/, error.message)
  end
end
