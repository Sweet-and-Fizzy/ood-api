# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/sessions'

class HandlersSessionsTest < Minitest::Test
  include TestHelpers

  def setup
    @home = Dir.mktmpdir('ood-sessions-home')
    @apps = Dir.mktmpdir('ood-sessions-apps')
    @saved = ENV.to_h.slice('HOME', 'OOD_API_SYS_APPS')
    ENV['HOME'] = @home
    ENV['OOD_API_SYS_APPS'] = @apps
    @db = File.join(@home, 'ondemand/data/sys/dashboard/batch_connect/db')
    FileUtils.mkdir_p(@db)
    @cluster = mock_cluster(id: 'hpc')
  end

  def teardown
    ENV['HOME'] = @saved['HOME']
    @saved['OOD_API_SYS_APPS'] ? ENV['OOD_API_SYS_APPS'] = @saved['OOD_API_SYS_APPS'] : ENV.delete('OOD_API_SYS_APPS')
    FileUtils.rm_rf([@home, @apps])
  end

  def record(id, **fields)
    fields = { 'id' => id, 'cluster_id' => 'hpc', 'token' => 'sys/jupyter' }.merge(fields)
    File.write(File.join(@db, id), JSON.generate(fields))
  end

  def app(name, title, form: 'form.yml')
    dir = File.join(@apps, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'manifest.yml'), "name: #{title}\ndescription: |\n  #{title} on a compute node\n")
    File.write(File.join(dir, form), "attributes: {}\n") if form
  end

  def test_sessions_come_newest_first_with_status_from_the_scheduler
    record('a', 'job_id' => '11', 'created_at' => 1_000, 'title' => 'JupyterLab')
    record('b', 'job_id' => '12', 'created_at' => 2_000, 'title' => 'JupyterLab', 'cache_completed' => true)
    adapter = mock('adapter')
    adapter.stubs(:info).with('11').returns(mock_job_info(id: '11', status: :running))
    @cluster.stubs(:job_adapter).returns(adapter)

    sessions = Handlers::Sessions.list(clusters: [@cluster])

    assert_equal ['b', 'a'], sessions.map(&:id)
    assert_equal ['completed', 'running'], sessions.map(&:status)
    assert_equal Time.at(1_000).iso8601, sessions.last.created_at
  end

  def test_a_session_on_an_unknown_cluster_or_a_failing_scheduler_is_unknown
    record('a', 'job_id' => '11', 'created_at' => 1, 'cluster_id' => 'gone')
    record('b', 'job_id' => '12', 'created_at' => 2)
    adapter = mock('adapter')
    adapter.stubs(:info).raises(StandardError, 'squeue failed')
    @cluster.stubs(:job_adapter).returns(adapter)

    assert_equal ['unknown', 'unknown'], Handlers::Sessions.list(clusters: [@cluster]).map(&:status)
  end

  def test_backups_and_unreadable_records_are_skipped
    record('good', 'job_id' => '1', 'created_at' => 1, 'cache_completed' => true)
    File.write(File.join(@db, 'good.bak'), '{}')
    File.write(File.join(@db, 'broken'), '{not json')

    assert_equal ['good'], Handlers::Sessions.list(clusters: []).map(&:id)
  end

  def test_with_no_records_directory_there_are_no_sessions
    FileUtils.rm_rf(@db)

    assert_empty Handlers::Sessions.list(clusters: [])
  end

  def test_a_session_without_a_title_takes_its_apps_name
    app('jupyter', 'JupyterLab')
    record('a', 'job_id' => '1', 'created_at' => 1, 'cache_completed' => true)

    assert_equal 'JupyterLab', Handlers::Sessions.list(clusters: []).first.title
  end

  def test_only_apps_with_a_form_are_interactive_apps
    app('jupyter', 'JupyterLab')
    app('bc_desktop', 'Desktop', form: 'form.yml.erb')
    app('files', 'Files', form: nil)

    apps = Handlers::Sessions.apps

    assert_equal ['sys/bc_desktop', 'sys/jupyter'], apps.map(&:token)
    assert_equal '/pun/sys/dashboard/batch_connect/sys/jupyter/session_contexts/new', apps.last.launch_page
    assert_equal 'JupyterLab on a compute node', apps.last.description
  end
end
