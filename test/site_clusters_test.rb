# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

class SiteClustersTest < Minitest::Test
  def setup
    @saved = ENV.fetch('OOD_CLUSTERS', nil)
    @dir = Dir.mktmpdir('clusters')
    ENV['OOD_CLUSTERS'] = @dir
    forget
    at(1000.0)
  end

  def teardown
    @saved ? ENV['OOD_CLUSTERS'] = @saved : ENV.delete('OOD_CLUSTERS')
    FileUtils.rm_rf(@dir)
    forget
  end

  def test_reads_the_clusters_in_the_directory
    write('hpc')
    write('gpu')

    assert_equal ['gpu', 'hpc'], ids
  end

  def test_a_change_within_a_second_is_not_looked_for
    write('hpc')
    ids
    write('gpu')
    at(1000.5)

    assert_equal ['hpc'], ids
  end

  def test_an_added_file_is_read_once_the_second_has_passed
    write('hpc')
    ids
    write('gpu')
    at(1001.5)

    assert_equal ['gpu', 'hpc'], ids
  end

  def test_a_changed_file_is_read_again
    write('hpc', title: 'Old')
    OodApi::SiteClusters.all
    write('hpc', title: 'A new and longer title')
    at(1001.5)

    assert_equal 'A new and longer title', OodApi::SiteClusters.all.first.metadata.title
  end

  def test_a_removed_file_stops_being_offered
    write('hpc')
    write('gpu')
    ids
    File.delete(File.join(@dir, 'gpu.yml'))
    at(1001.5)

    assert_equal ['hpc'], ids
  end

  def test_unchanged_files_are_not_parsed_again
    write('hpc')
    first = OodApi::SiteClusters.all
    at(1001.5)
    OodCore::Clusters.expects(:load_file).never

    assert_same first, OodApi::SiteClusters.all
  end

  def test_a_missing_directory_is_a_configuration_error_naming_it
    ENV['OOD_CLUSTERS'] = File.join(@dir, 'missing')

    error = assert_raises(Handlers::ConfigurationError) { OodApi::SiteClusters.all }
    assert_includes error.message, File.join(@dir, 'missing')
  end

  def test_a_directory_created_later_is_read
    missing = File.join(@dir, 'later')
    ENV['OOD_CLUSTERS'] = missing
    assert_raises(Handlers::ConfigurationError) { OodApi::SiteClusters.all }

    Dir.mkdir(missing)
    File.write(File.join(missing, 'hpc.yml'), cluster_yaml('HPC'))
    at(1001.5)

    assert_equal ['hpc'], ids
  end

  private

  def ids
    OodApi::SiteClusters.all.map { |c| c.id.to_s }.sort
  end

  def write(id, title: id.upcase)
    File.write(File.join(@dir, "#{id}.yml"), cluster_yaml(title))
  end

  def cluster_yaml(title)
    <<~YAML
      v2:
        metadata:
          title: #{title}
        login:
          host: login.example.edu
        job:
          adapter: slurm
    YAML
  end

  # The module keeps its last answer between calls; each test starts clean.
  def forget
    [:@all, :@stamp, :@checked].each { |v| OodApi::SiteClusters.instance_variable_set(v, nil) }
  end

  def at(seconds)
    OodApi::SiteClusters.stubs(:now).returns(seconds)
  end
end
