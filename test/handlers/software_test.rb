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

  def test_clusters_with_no_or_a_broken_file_are_named
    File.write(File.join(@dir, 'gpu.json'), '{not json')
    @clusters << mock_cluster(id: 'other')

    result = Handlers::Software.find(clusters: @clusters)
    assert_equal ['gcc', 'py-torch', 'python'], result[:modules].map(&:name)
    assert_equal ['gpu', 'other'], result[:unlisted]
  end

  def test_an_exact_name_comes_first_then_names_that_start_with_it
    many = (1..60).to_h { |i| ["libr#{i}", { '/m' => { 'Version' => '1' } }] }
    many['r'] = { '/r' => { 'Version' => '4.4.1' } }
    many['rstudio'] = { '/rs' => { 'Version' => '2024.1' } }
    File.write(File.join(@dir, 'hpc.json'), JSON.generate(many))

    names = Handlers::Software.find(clusters: @clusters, name: 'R')[:modules].map(&:name)
    assert_equal ['r', 'rstudio'], names.first(2)
  end

  def test_versions_sort_piece_by_piece
    versions = ['3.9.1', '3.10.2', '11.8.0', '11.8.0-gcc', 'R2023b', 'R2024a']
    spider = { 'x' => versions.to_h { |v| ["/x/#{v}", { 'Version' => v }] } }
    File.write(File.join(@dir, 'hpc.json'), JSON.generate(spider))

    found = Handlers::Software.find(clusters: @clusters, name: 'x')[:modules].first.versions.map(&:version)
    assert_equal ['R2024a', 'R2023b', '11.8.0-gcc', '11.8.0', '3.10.2', '3.9.1'], found
  end

  def test_a_file_is_parsed_once_until_it_changes
    path = File.join(@dir, 'hpc.json')
    Handlers::Software.expects(:in_child).twice.yields.returns([])
    2.times { Handlers::Software.find(clusters: [@clusters.first]) }

    File.write(path, JSON.generate(SPIDER.merge('extra' => {})))
    Handlers::Software.find(clusters: [@clusters.first])
  end

  def test_the_parse_runs_in_a_child_and_only_its_result_comes_back
    parent = Process.pid
    child, list = Handlers::Software.in_child { [Process.pid, Handlers::Software.spider(Pathname.new(File.join(@dir, 'hpc.json')))] }

    refute_equal parent, child
    assert_includes list, ['python', '3.12.4', [['gcc/12.3.0'], ['intel/2024.1']]]
    assert_nil Handlers::Software.in_child { raise 'boom' }, 'a child that fails gives nothing'
  end

  def test_repeated_names_and_prerequisites_are_one_object
    kept = Handlers::Software.modules([['a', '1', [['gcc/12']]], ['a', '2', [['gcc/12']]]], 'hpc')

    assert kept[0][:name].equal?(kept[1][:name])
    assert kept[0][:version].prerequisites.equal?(kept[1][:version].prerequisites)
    assert kept[0][:version].cluster_id.equal?(kept[1][:version].cluster_id)
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
