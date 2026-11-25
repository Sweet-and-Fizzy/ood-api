# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/sessions'

class HandlersSessionsTest < Minitest::Test
  include TestHelpers

  def setup
    @home = Dir.mktmpdir('ood-sessions-home')
    @apps = Dir.mktmpdir('ood-sessions-apps')
    @saved = ENV.to_h.slice('HOME', 'OOD_API_SYS_APPS')
    OodApi::SiteConfig.stubs(:dashboard_env).returns({})
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
    record('c', 'job_id' => '9', 'created_at' => 500)
    adapter = mock('adapter')
    adapter.expects(:info_where_owner).with('jesse').once.returns([mock_job_info(id: '11', status: :running)])
    @cluster.stubs(:job_adapter).returns(adapter)

    sessions = Handlers::Sessions.list(clusters: [@cluster], user: 'jesse')

    assert_equal ['b', 'a', 'c'], sessions.map(&:id)
    assert_equal ['completed', 'running', 'completed'], sessions.map(&:status), 'a job no longer listed has finished'
    assert_equal Time.at(1_000).iso8601, sessions[1].created_at
  end

  def test_the_dashboards_data_root_is_followed
    root = File.join(@home, 'elsewhere')
    FileUtils.mkdir_p(File.join(root, 'batch_connect/db'))
    File.write(File.join(root, 'batch_connect/db/x'), JSON.generate('id' => 'x', 'cache_completed' => true))
    OodApi::SiteConfig.stubs(:dashboard_env).returns({ 'OOD_DATAROOT' => root })

    assert_equal ['x'], Handlers::Sessions.list(clusters: []).map(&:id)
  end

  def test_an_odd_created_at_or_unreadable_db_does_not_fail
    record('a', 'created_at' => { 'nested' => 1 }, 'cache_completed' => true)
    record('b', 'created_at' => 5, 'cache_completed' => true)

    assert_equal ['b', 'a'], Handlers::Sessions.list(clusters: []).map(&:id)
    Handlers::Sessions.stubs(:db).returns(Pathname.new('/nonexistent/db'))
    assert_empty Handlers::Sessions.list(clusters: [])
  end

  def test_a_session_on_an_unknown_cluster_or_a_failing_scheduler_is_unknown
    record('a', 'job_id' => '11', 'created_at' => 1, 'cluster_id' => 'gone')
    record('b', 'job_id' => '12', 'created_at' => 2)
    adapter = mock('adapter')
    adapter.stubs(:info_where_owner).raises(StandardError, 'squeue failed')
    @cluster.stubs(:job_adapter).returns(adapter)

    assert_equal ['unknown', 'unknown'], Handlers::Sessions.list(clusters: [@cluster], user: 'jesse').map(&:status)
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

class HandlersSessionsFieldsTest < Minitest::Test
  def setup
    @apps = Dir.mktmpdir('ood-sessions-fields')
    @config = Dir.mktmpdir('ood-sessions-config')
    @saved = ENV.to_h.slice('OOD_API_SYS_APPS', 'OOD_BC_APP_CONFIG_ROOT')
    ENV['OOD_API_SYS_APPS'] = @apps
    ENV['OOD_BC_APP_CONFIG_ROOT'] = @config
    OodApi::SiteConfig.stubs(:dashboard_env).returns({})
  end

  def teardown
    ['OOD_API_SYS_APPS', 'OOD_BC_APP_CONFIG_ROOT'].each { |k| @saved[k] ? ENV[k] = @saved[k] : ENV.delete(k) }
    FileUtils.rm_rf([@apps, @config])
  end

  def test_each_sub_app_is_listed_with_its_own_page_and_merged_form
    dir = File.join(@apps, 'bc_desktop')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'manifest.yml'), "name: Desktop\ndescription: A desktop\n")
    File.write(File.join(dir, 'form.yml'), "form:\n  - desktop\n  - bc_num_hours\nattributes:\n  desktop: mate\n")
    FileUtils.mkdir_p(File.join(@config, 'bc_desktop'))
    File.write(File.join(@config, 'bc_desktop', 'owens.yml'), "title: Owens Desktop\ncluster: owens\n")
    File.write(File.join(@config, 'bc_desktop', 'pitzer.yml'), "cluster: pitzer\nattributes:\n  bc_num_hours: 1\n")

    apps = Handlers::Sessions.apps

    assert_equal ['sys/bc_desktop/owens', 'sys/bc_desktop/pitzer'], apps.map(&:token)
    assert_equal ['Owens Desktop', 'Desktop: Pitzer'], apps.map(&:title)
    assert_equal '/pun/sys/dashboard/batch_connect/sys/bc_desktop/owens/session_contexts/new', apps.first.launch_page
    assert_equal ['Number of hours'], apps.first.fields
    assert_empty apps.last.fields, 'the sub-app fixed the hours'
  end

  def test_the_forms_own_title_and_description_win_and_erb_is_read_first
    dir = File.join(@apps, 'jupyter')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'manifest.yml'), "name: Jupyter\ndescription: From the manifest\n")
    File.write(File.join(dir, 'form.yml'), "title: Jupyter Lab\ndescription: From the form\nform:\n  - bc_num_hours\n")
    assert_equal ['Jupyter Lab', 'From the form'], [Handlers::Sessions.apps.first.title, Handlers::Sessions.apps.first.description]

    File.write(File.join(dir, 'form.yml.erb'), "form:\n  - <%= 'x' %>\n")
    assert_empty Handlers::Sessions.apps.first.fields
  end

  def test_an_apps_fields_are_listed_in_order_with_their_labels
    dir = File.join(@apps, 'rstudio')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'manifest.yml'), "name: RStudio\n")
    File.write(File.join(dir, 'form.yml'), <<~YAML)
      cluster: hpc
      form:
        - version
        - bc_num_hours
        - bc_account
        - fixed_thing
      attributes:
        version:
          label: R version
          widget: select
        fixed_thing: some-value
    YAML

    assert_equal ['R version', 'Number of hours', 'Account'], Handlers::Sessions.apps.first.fields
  end

  def test_a_templated_form_lists_no_fields
    dir = File.join(@apps, 'desktop')
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'manifest.yml'), "name: Desktop\n")
    File.write(File.join(dir, 'form.yml.erb'), "form:\n  - <%= 'x' %>\n")

    assert_empty Handlers::Sessions.apps.first.fields
  end
end
