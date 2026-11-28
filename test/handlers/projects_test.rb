# frozen_string_literal: true

require 'timeout'
require_relative '../test_helper'
require_relative '../../app/handlers/projects'

class HandlersProjectsTest < Minitest::Test
  include TestHelpers

  Projects = Handlers::Projects

  def setup
    @home = File.realpath(Dir.mktmpdir('ood-projects-home'))
    @data = File.join(@home, 'ondemand/data/sys/dashboard')
    OodApi::SiteConfig.stubs(:dashboard_env).returns({ 'OOD_DATAROOT' => @data })
    OodApi::SiteConfig.stubs(:shared_project_paths).returns([])
    OodApi::SiteConfig.stubs(:allowlist_paths).returns([Pathname.new(@home)])
    FileUtils.mkdir_p(File.join(@data, 'projects'))
    @cluster = mock_cluster(id: 'hpc')
  end

  def teardown
    FileUtils.rm_rf(@home)
  end

  def lookup_file
    File.join(@data, 'projects', '.project_lookup')
  end

  def lookup(table)
    File.write(lookup_file, table.to_yaml)
  end

  def project(id, name, dir: File.join(@home, 'projects', id), description: nil)
    FileUtils.mkdir_p(File.join(dir, '.ondemand', 'launchers'))
    File.write(File.join(dir, '.ondemand', 'manifest.yml'),
               { 'id' => id, 'name' => name, 'description' => description, 'icon' => 'fas://cog' }.compact.to_yaml)
    dir
  end

  def launcher(dir, id, title, form: ['auto_scripts', 'bc_num_hours'], created_at: 1_000)
    path = File.join(dir, '.ondemand', 'launchers', id)
    FileUtils.mkdir_p(path)
    attributes = { 'bc_num_hours' => { 'value' => '4', 'max' => 48 } }
    File.write(File.join(path, 'form.yml'),
               { 'title' => title, 'created_at' => created_at, 'form' => form, 'attributes' => attributes }.to_yaml)
  end

  def test_no_lookup_file_means_no_projects_and_none_is_created
    assert_empty Projects.list[:projects]
    refute File.exist?(lookup_file)
  end

  def test_an_empty_lookup_file_means_no_projects
    File.write(lookup_file, '')

    assert_empty Projects.list[:projects]
  end

  def test_lists_projects_with_their_manifest
    dir = project('abc12345', 'Cell growth', description: 'Plate reader fits')
    lookup('abc12345' => dir)

    found = Projects.list[:projects]

    assert_equal 1, found.size
    assert_equal ['abc12345', 'Cell growth', 'Plate reader fits', dir, '/pun/sys/dashboard/projects/abc12345'],
                 [found[0].id, found[0].name, found[0].description, found[0].directory, found[0].page]
    assert_nil found[0].problem
  end

  def test_an_unreadable_lookup_file_is_unavailable_not_empty
    File.write(lookup_file, "- just\n- a list\n")
    assert_raises(Projects::Unavailable) { Projects.list }

    File.write(lookup_file, "abc: [unclosed\n")
    assert_raises(Projects::Unavailable) { Projects.list }
  end

  def test_a_lookup_file_past_the_size_limit_is_unavailable
    File.write(lookup_file, "a: #{'x' * Projects::LOOKUP_LIMIT}\n")

    error = assert_raises(Projects::Unavailable) { Projects.list }
    assert_includes error.message, 'larger than'
  end

  def test_yaml_aliases_and_objects_are_refused
    File.write(lookup_file, "a: &x /tmp\nb: *x\n")
    assert_raises(Projects::Unavailable) { Projects.list }

    File.write(lookup_file, "a: !ruby/object:OpenStruct {}\n")
    assert_raises(Projects::Unavailable) { Projects.list }
  end

  def test_projects_past_the_limit_are_counted
    table = (1..(Projects::MAX_PROJECTS + 3)).to_h { |n| ["p#{n}", File.join(@home, "missing#{n}")] }
    lookup(table)

    result = Projects.list
    assert_equal Projects::MAX_PROJECTS, result[:projects].size
    assert_equal 3, result[:more]
  end

  def test_a_project_outside_home_and_the_shared_locations_is_refused
    outside = File.realpath(Dir.mktmpdir('ood-projects-outside'))
    project('abc12345', 'Elsewhere', dir: outside)
    lookup('abc12345' => outside)

    found = Projects.list[:projects].first
    assert_match(/outside the places this site lets the assistant read/, found.problem)
    assert_equal 'abc12345', found.name
  ensure
    FileUtils.rm_rf(outside)
  end

  def test_a_shared_location_is_allowed
    shared = File.realpath(Dir.mktmpdir('ood-projects-shared'))
    dir = project('abc12345', 'Group work', dir: File.join(shared, 'lab', 'growth'))
    OodApi::SiteConfig.stubs(:shared_project_paths).returns([Pathname.new(shared)])
    lookup('abc12345' => dir)

    assert_nil Projects.list[:projects].first.problem
  ensure
    FileUtils.rm_rf(shared)
  end

  def test_a_link_from_home_to_elsewhere_is_followed_and_refused
    outside = File.realpath(Dir.mktmpdir('ood-projects-outside'))
    project('abc12345', 'Linked', dir: outside)
    link = File.join(@home, 'linked')
    File.symlink(outside, link)
    lookup('abc12345' => link)

    assert_match(/outside the places/, Projects.list[:projects].first.problem)
  ensure
    FileUtils.rm_rf(outside)
  end

  def test_a_manifest_linked_outside_the_project_is_refused
    dir = File.join(@home, 'projects', 'abc12345')
    FileUtils.mkdir_p(File.join(dir, '.ondemand'))
    secret = File.join(@home, 'secret.yml')
    File.write(secret, "name: secret\n")
    File.symlink(secret, File.join(dir, '.ondemand', 'manifest.yml'))
    lookup('abc12345' => dir)

    assert_match(/links outside the project/, Projects.list[:projects].first.problem)
  end

  def test_a_missing_directory_is_unavailable
    lookup('abc12345' => File.join(@home, 'gone'))

    assert_match(/no longer exists/, Projects.list[:projects].first.problem)
  end

  def test_get_gives_launchers_oldest_first_with_field_ids_only
    dir = project('abc12345', 'Cell growth')
    launcher(dir, 'zzzz0002', 'Second', created_at: 2_000)
    launcher(dir, 'aaaa0001', 'First', created_at: 1_000, form: ['auto_accounts'])
    FileUtils.mkdir_p(File.join(dir, '.ondemand', 'launchers', 'not-an-id'))
    File.write(File.join(dir, '.ondemand', 'launchers', 'not-an-id', 'form.yml'), "title: Bad\n")
    lookup('abc12345' => dir)

    details = Projects.get('abc12345', clusters: [@cluster], user: 'jesse')

    assert_equal ['aaaa0001', 'zzzz0002'], details.launchers.map(&:id)
    assert_equal [['auto_accounts'], ['auto_scripts', 'bc_num_hours']], details.launchers.map(&:fields)
    assert_equal '/pun/sys/dashboard/projects/abc12345/launchers/aaaa0001', details.launchers[0].page
    assert_equal [:id, :title, :fields, :page], details.launchers[0].to_h.keys
  end

  def test_a_teammates_job_is_asked_about_by_id_not_called_completed
    dir = project('abc12345', 'Shared lab')
    File.write(File.join(dir, '.ondemand', 'job_log.yml'),
               [{ 'id' => '201', 'cluster' => 'hpc', 'status' => 'running', 'job_owner' => 'bob' },
                { 'id' => '202', 'cluster' => 'hpc', 'status' => 'queued', 'job_owner' => 'bob' }].to_yaml)
    lookup('abc12345' => dir)
    adapter = mock('adapter')
    adapter.stubs(:info_where_owner).with('jesse').returns([])
    adapter.stubs(:info).with('201').returns(mock_job_info(id: '201', status: :running))
    adapter.stubs(:info).with('202').raises(StandardError, 'scheduler down')
    @cluster.stubs(:job_adapter).returns(adapter)

    jobs = Projects.get('abc12345', clusters: [@cluster], user: 'jesse').jobs
    assert_equal({ '202' => 'unknown', '201' => 'running' }, jobs.to_h { |j| [j.id, j.status] })
  end

  def test_a_job_log_as_the_dashboard_writes_it
    dir = project('abc12345', 'Cell growth')
    native = { 'account' => 'pzs0714', 'job_id' => '101', 'job_name' => 'fit', 'state' => 'COMPLETED',
               'partition' => 'batch', 'reason' => 'None', 'nodes' => '1', 'min_memory' => '4G',
               'time_limit' => '1:00:00', 'time_used' => '0:01:00', 'nodelist' => 'hpc-c1',
               'work_dir' => '/home/jesse/projects/growth', 'start_time' => '2026-11-27T10:00:00',
               'submit_time' => '2026-11-27T09:59:00', 'gres' => 'N/A', 'tres_alloc' => 'cpu=4,mem=4G,node=1' }
    log = [{ 'id' => '101', 'status' => 'completed', 'allocated_nodes' => [], 'submit_host' => nil,
             'job_name' => 'fit', 'job_owner' => 'jesse', 'accounting_id' => 'pzs0714', 'procs' => 4,
             'queue_name' => 'batch', 'wallclock_time' => 60, 'wallclock_limit' => 3600, 'cpu_time' => nil,
             'submission_time' => Time.at(1_000), 'dispatch_time' => Time.at(1_060), 'native' => native,
             'gpus' => 0, 'tasks' => [], 'cluster' => 'hpc' }]
    File.write(File.join(dir, '.ondemand', 'job_log.yml'), log.to_yaml)
    lookup('abc12345' => dir)

    job = Projects.get('abc12345', clusters: [@cluster], user: 'jesse').jobs.first
    assert_equal ['101', 'fit', 'hpc', 'completed', Time.at(1_000).iso8601],
                 [job.id, job.name, job.cluster_id, job.status, job.submitted_at]
  end

  def test_a_pipe_in_place_of_a_file_is_refused_without_waiting
    dir = project('abc12345', 'Cell growth')
    File.mkfifo(File.join(dir, '.ondemand', 'job_log.yml'))
    lookup('abc12345' => dir)

    details = Timeout.timeout(5) { Projects.get('abc12345', clusters: [], user: 'jesse') }
    assert_match(/not a regular file/, details.jobs_problem)
  end

  def test_a_dangling_job_log_link_is_unavailable_not_empty
    dir = project('abc12345', 'Cell growth')
    File.symlink(File.join(dir, 'nowhere'), File.join(dir, '.ondemand', 'job_log.yml'))
    lookup('abc12345' => dir)

    assert_match(/link to nothing/, Projects.get('abc12345', clusters: [], user: 'jesse').jobs_problem)
  end

  def test_a_dangling_lookup_link_is_unavailable_not_empty
    File.symlink(File.join(@home, 'nowhere'), lookup_file)

    assert_raises(Projects::Unavailable) { Projects.list }
  end

  def test_a_project_in_a_data_root_outside_home_is_allowed
    scratch = File.realpath(Dir.mktmpdir('ood-projects-scratch'))
    OodApi::SiteConfig.stubs(:dashboard_env).returns({ 'OOD_DATAROOT' => scratch })
    FileUtils.mkdir_p(File.join(scratch, 'projects'))
    dir = project('abc12345', 'Default place', dir: File.join(scratch, 'projects', 'abc12345'))
    File.write(File.join(scratch, 'projects', '.project_lookup'), { 'abc12345' => dir }.to_yaml)

    assert_nil Projects.list[:projects].first.problem
  ensure
    FileUtils.rm_rf(scratch)
  end

  def test_a_shared_root_of_slash_or_a_relative_path_allows_nothing
    outside = File.realpath(Dir.mktmpdir('ood-projects-outside'))
    project('abc12345', 'Elsewhere', dir: outside)
    OodApi::SiteConfig.stubs(:shared_project_paths).returns([Pathname.new('/'), Pathname.new('relative')])
    lookup('abc12345' => outside)

    assert_match(/outside/, Projects.list[:projects].first.problem)
  ensure
    FileUtils.rm_rf(outside)
  end

  def test_logged_jobs_are_newest_first_with_last_known_and_current_status
    dir = project('abc12345', 'Cell growth')
    log = [
      { 'id' => '101', 'cluster' => 'hpc', 'status' => 'completed', 'job_name' => 'fit',
        'submission_time' => Time.at(1_000) },
      { 'id' => '102', 'cluster' => 'hpc', 'status' => 'queued', 'job_name' => 'fit2' },
      { 'id' => '103', 'cluster' => 'hpc', 'status' => 'running', 'job_name' => 'fit3' }
    ]
    File.write(File.join(dir, '.ondemand', 'job_log.yml'), log.to_yaml)
    lookup('abc12345' => dir)
    adapter = mock('adapter')
    adapter.expects(:info_where_owner).with('jesse').once.returns([mock_job_info(id: '103', status: :running)])
    adapter.expects(:info).with('102').once.returns(mock_job_info(id: '102', status: :completed))
    @cluster.stubs(:job_adapter).returns(adapter)

    jobs = Projects.get('abc12345', clusters: [@cluster], user: 'jesse').jobs

    assert_equal ['103', '102', '101'], jobs.map(&:id)
    assert_equal ['running', 'queued', 'completed'], jobs.map(&:last_known_status)
    assert_equal ['running', 'completed', 'completed'], jobs.map(&:status)
    assert_equal Time.at(1_000).iso8601, jobs.last.submitted_at
  end

  def test_jobs_on_a_cluster_that_cannot_be_asked_are_unknown_now
    dir = project('abc12345', 'Cell growth')
    File.write(File.join(dir, '.ondemand', 'job_log.yml'),
               [{ 'id' => '102', 'cluster' => 'gone', 'status' => 'queued' }].to_yaml)
    lookup('abc12345' => dir)

    job = Projects.get('abc12345', clusters: [@cluster], user: 'jesse').jobs.first
    assert_equal ['queued', 'unknown'], [job.last_known_status, job.status]
  end

  def test_an_unreadable_job_log_is_unavailable_and_launchers_still_show
    dir = project('abc12345', 'Cell growth')
    launcher(dir, 'aaaa0001', 'First')
    File.write(File.join(dir, '.ondemand', 'job_log.yml'), "{ broken\n")
    lookup('abc12345' => dir)

    details = Projects.get('abc12345', clusters: [], user: 'jesse')
    assert_match(/could not be understood/, details.jobs_problem)
    assert_equal ['aaaa0001'], details.launchers.map(&:id)
  end

  def test_get_refuses_an_unknown_or_malformed_id
    lookup({})

    assert_raises(Handlers::NotFoundError) { Projects.get('nope', clusters: []) }
    assert_raises(Handlers::NotFoundError) { Projects.get('../../etc', clusters: []) }
  end

  def test_launcher_gives_its_page
    dir = project('abc12345', 'Cell growth')
    launcher(dir, 'aaaa0001', 'Fit plates')
    lookup('abc12345' => dir)

    found, opened = Projects.launcher('abc12345', 'aaaa0001')
    assert_equal 'Cell growth', found.name
    assert_equal ['Fit plates', '/pun/sys/dashboard/projects/abc12345/launchers/aaaa0001'], [opened.title, opened.page]
  end

  def test_launcher_refuses_an_unknown_or_malformed_launcher
    dir = project('abc12345', 'Cell growth')
    lookup('abc12345' => dir)

    assert_raises(Handlers::NotFoundError) { Projects.launcher('abc12345', 'aaaa0001') }
    assert_raises(Handlers::NotFoundError) { Projects.launcher('abc12345', '../../x') }
  end

  def test_the_data_root_follows_the_dashboards_env_file
    assert_equal Pathname.new(File.join(@data, 'projects')), Projects.data_root
  end

  def test_jobs_on_a_cluster_the_site_does_not_offer_are_not_asked_about
    hidden = mock_cluster(id: 'secret', hidden: true)
    hidden.expects(:job_adapter).never
    closed = mock_cluster(id: 'closed')
    closed.stubs(:job_allow?).returns(false)
    closed.expects(:job_adapter).never
    dir = project('abc12345', 'Cell growth')
    File.write(File.join(dir, '.ondemand', 'job_log.yml'),
               [{ 'id' => '1', 'cluster' => 'secret', 'status' => 'running' },
                { 'id' => '2', 'cluster' => 'closed', 'status' => 'running' }].to_yaml)
    lookup('abc12345' => dir)

    jobs = Projects.get('abc12345', clusters: [hidden, closed], user: 'jesse').jobs
    assert_equal ['unknown', 'unknown'], jobs.map(&:status)
  end

  def test_a_scheduler_that_does_not_answer_is_not_asked_once_per_job
    dir = project('abc12345', 'Cell growth')
    log = (1..10).map { |n| { 'id' => n.to_s, 'cluster' => 'hpc', 'status' => 'queued', 'job_owner' => 'bob' } }
    File.write(File.join(dir, '.ondemand', 'job_log.yml'), log.to_yaml)
    lookup('abc12345' => dir)
    adapter = mock('adapter')
    adapter.expects(:info_where_owner).once.raises(StandardError, 'slurmctld down')
    adapter.expects(:info).never
    @cluster.stubs(:job_adapter).returns(adapter)

    jobs = Projects.get('abc12345', clusters: [@cluster], user: 'jesse').jobs
    assert_equal ['unknown'] * 10, jobs.map(&:status)
  end

  def test_a_nul_in_a_project_directory_is_unavailable_not_a_failure
    File.write(lookup_file, "abc12345: \"/home/a\\0b\"\nother: #{File.join(@home, 'gone')}\n")

    found = Projects.list[:projects]
    assert_equal ['abc12345', 'other'], found.map(&:id)
    assert_match(/could not be understood/, found.first.problem)
    refute_includes found.first.directory, "\0"
  end

  def test_one_bad_launcher_is_that_launchers_problem_only
    dir = project('abc12345', 'Cell growth')
    path = File.join(dir, '.ondemand', 'launchers', 'aaaa0001')
    FileUtils.mkdir_p(path)
    File.write(File.join(path, 'form.yml'), "{ broken\n")
    lookup('abc12345' => dir)

    error = assert_raises(Projects::LauncherUnavailable) { Projects.launcher('abc12345', 'aaaa0001') }
    assert_kind_of Handlers::Error, error
  end

  def test_without_an_allowlist_the_file_tools_roots_are_used
    OodApi::SiteConfig.stubs(:allowlist_paths).returns([])

    roots = Projects.allowed_roots
    assert_includes roots, Pathname.new(Dir.home).realpath
  end

  def test_a_finished_job_carries_the_schedulers_own_state
    dir = project('abc12345', 'Cell growth')
    log = [{ 'id' => '101', 'cluster' => 'hpc', 'status' => 'completed', 'native' => { 'state' => 'FAILED' } },
           { 'id' => '102', 'cluster' => 'hpc', 'status' => 'running', 'job_owner' => 'bob' }]
    File.write(File.join(dir, '.ondemand', 'job_log.yml'), log.to_yaml)
    lookup('abc12345' => dir)
    adapter = mock('adapter')
    adapter.stubs(:info_where_owner).returns([])
    adapter.stubs(:info).with('102').returns(mock_job_info(id: '102', status: :completed,
                                                           native: { state: 'OUT_OF_MEMORY' }))
    @cluster.stubs(:job_adapter).returns(adapter)

    jobs = Projects.get('abc12345', clusters: [@cluster], user: 'jesse').jobs.to_h do |j|
      [j.id, [j.last_known_status, j.status]]
    end
    assert_equal ['completed (failed)', 'completed (failed)'], jobs['101']
    assert_equal ['running', 'completed (out_of_memory)'], jobs['102']
  end
end
