# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/jobs'
require 'tmpdir'

class HandlersJobsTest < Minitest::Test
  # Local copy: the files test defines its own, and these two suites do not
  # share a helper module.
  def with_fake_home
    Dir.mktmpdir('jobs_home') do |fake|
      Dir.stub(:home, fake) { yield fake }
    end
  end

  # `native` is raw scheduler argv, and ood_core appends it AFTER the options
  # this handler validated — the Slurm adapter builds `-o script.output_path`
  # then concatenates native. sbatch honours the last occurrence of a repeated
  # flag, so `--output=` in native silently overrode the path job_path! had
  # just approved: the same file was refused as output_path and accepted as
  # native. That defeats the invariant SECURITY.md states, and the deny-list is
  # not a privilege control — the point is that an agent on injected input
  # cannot reach ~/.ssh/authorized_keys.
  def test_native_path_flags_are_validated_like_output_path
    with_fake_home do |home|
      denied = File.join(home, '.ssh', 'authorized_keys')
      [["--output=#{denied}"], ['-o', denied], ["--error=#{denied}"], ['-e', denied],
       ["--chdir=#{File.dirname(denied)}"], ['-D', File.dirname(denied)],
       ['-N', '2', "--output=#{denied}"]].each do |native|
        assert_raises(Handlers::ForbiddenError, "native #{native.inspect} must be refused") do
          Handlers::Jobs.validate_native_paths!(native)
        end
      end
    end
  end

  # native is raw scheduler argv. Every other OOD system takes it from a
  # trusted source — Batch Connect from the site admin's submit.yml.erb,
  # filtered through Rails strong params; Job Composer from a file the user
  # wrote. The ecosystem tolerates it because OOD ships a Shell app, so a user
  # who can set native already has a terminal. An agent driving this API has
  # no shell, which is why it is off unless a site opts in.
  def test_native_is_refused_unless_the_site_opts_in
    ENV.delete('OOD_API_ALLOW_NATIVE')

    assert_raises(Handlers::ValidationError) { Handlers::Jobs.reject_native!(['-N', '2']) }
    # Absent or empty is not an opt-in question.
    Handlers::Jobs.reject_native!(nil)
    Handlers::Jobs.reject_native!([])
  end

  # Strict `== 'true'`, matching AppAuth.enabled?. A site that means to enable
  # this should have to spell it exactly.
  def test_native_opt_in_requires_the_exact_string
    ['TRUE', 'True', '1', 'yes', 'on'].each do |value|
      ENV['OOD_API_ALLOW_NATIVE'] = value
      assert_raises(Handlers::ValidationError, "#{value} must not enable native") do
        Handlers::Jobs.reject_native!(['-N', '2'])
      end
    end
  ensure
    ENV.delete('OOD_API_ALLOW_NATIVE')
  end

  # sbatch lets command-line options beat #SBATCH directives, and ood_core
  # emits `-o` only when output_path is set — so with none, a directive in the
  # script body took effect and reached a path the same request would be
  # refused for as output_path. Always supplying one closes that, and the
  # default is where Slurm would have written anyway.
  def test_output_path_is_always_supplied_so_script_directives_cannot_win
    with_fake_home do |home|
      # Through submit, not the helper: a test that only checks
      # default_output_path still passes if the merge is dropped, which is
      # exactly the wiring that closes this.
      captured = nil
      @adapter.expects(:submit).with do |script|
        captured = script.output_path
        true
      end.returns('789')
      @adapter.expects(:info).with('789').returns(mock_job_info(id: '789'))

      Handlers::Jobs.submit(clusters: @clusters, cluster_id: 'cluster1',
                            script_content: "#!/bin/bash\n#SBATCH --output=/tmp/evil\n",
                            workdir: home)

      refute_nil captured, 'submit must supply an output_path even when the caller omits one'
      assert captured.to_s.start_with?(home), 'the default must sit inside the validated workdir'
    end
  end

  # getopt_long treats `-o/path` as identical to `-o /path`, so validating only
  # the separated form left the bundled one through — the same destination the
  # separated form refuses.
  def test_native_bundled_short_flags_are_validated
    with_fake_home do |home|
      denied = File.join(home, '.ssh', 'authorized_keys')
      [["-o#{denied}"], ["-e#{denied}"], ["-D#{File.dirname(denied)}"],
       ["-oo#{denied}"], ['-N', '2', "-o#{denied}"]].each do |native|
        assert_raises(Handlers::ForbiddenError, "native #{native.inspect} must be refused") do
          Handlers::Jobs.validate_native_paths!(native)
        end
      end
    end
  end

  # JSON parses `1e400` to Float::INFINITY, and Integer(Infinity) raises
  # FloatDomainError — a RangeError, which escaped a rescue listing only
  # TypeError and ArgumentError. A client sending an oversized literal got a
  # 500 instead of a 400.
  def test_wall_time_rejects_values_that_are_not_finite_integers
    # JSON.parse turns an oversized literal into Float::INFINITY, which is how
    # this arrives from a real request body.
    from_json = JSON.parse('{"wall_time":1e400}')['wall_time']
    assert_equal Float::INFINITY, from_json

    [from_json, Float::INFINITY, -Float::INFINITY, Float::NAN, 'abc', {}, []].each do |value|
      assert_raises(Handlers::ValidationError, "wall_time #{value.inspect} must be a 400") do
        Handlers::Jobs.validate_wall_time(value)
      end
    end

    assert_equal 3600, Handlers::Jobs.validate_wall_time(3600)
    assert_equal 3600, Handlers::Jobs.validate_wall_time('3600')
    assert_nil Handlers::Jobs.validate_wall_time(nil)
  end

  # validate_native_paths! returned early unless native was an Array, so a
  # String, Hash or nested Array skipped path validation entirely and left the
  # outcome to whatever ood_core made of the shape. Refuse it instead.
  def test_native_must_be_a_flat_array_of_strings
    with_fake_home do |home|
      denied = File.join(home, '.ssh', 'authorized_keys')
      ["--output=#{denied}", { 'output' => denied }, [["--output=#{denied}"]],
       [{ 'output' => denied }], [nil]].each do |native|
        assert_raises(Handlers::ValidationError, "native #{native.inspect} must be refused") do
          Handlers::Jobs.validate_native_paths!(native)
        end
      end

      # A flat array of strings is still accepted, and numbers still work
      # because `--nodes 4` is an ordinary way to write scheduler argv.
      Handlers::Jobs.validate_native_paths!(['--nodes', 4])
      Handlers::Jobs.validate_native_paths!(['--exclusive'])
    end
  end

  # getopt_long accepts any unambiguous abbreviation, so sbatch reads `--out=`
  # as `--output=`. Matching exact spellings refused `--output=` and accepted
  # `--out=` — the same file, one spelling apart.
  def test_native_abbreviated_long_flags_are_validated
    with_fake_home do |home|
      denied = File.join(home, '.ssh', 'authorized_keys')
      dir = File.dirname(denied)
      [["--out=#{denied}"], ["--outp=#{denied}"], ["--outpu=#{denied}"],
       ["--o=#{denied}"], ['--out', denied], ["--err=#{denied}"],
       ["--erro=#{denied}"], ["--chdi=#{dir}"], ["--workdi=#{dir}"]].each do |native|
        assert_raises(Handlers::ForbiddenError, "native #{native.inspect} must be refused") do
          Handlers::Jobs.validate_native_paths!(native)
        end
      end
    end
  end

  # An abbreviation is only a prefix of the real flag. `--outputfoo` is a
  # different option, and unrelated long flags must still pass through or
  # every site using native passthrough breaks.
  def test_native_long_flags_that_are_not_abbreviations_are_left_alone
    with_fake_home do |home|
      denied = File.join(home, '.ssh', 'authorized_keys')
      [["--outputfoo=#{denied}"], ["--nodes=#{denied}"], ["--partition=#{denied}"],
       ["--x=#{denied}"], ['--exclusive'], ['--nodes=4'], ['--']].each do |native|
        Handlers::Jobs.validate_native_paths!(native)
      end
    end
  end

  # A bundle that merely starts with a path flag's letters is a different
  # option — `-N2` is not `-N` with the path "2", and long flags are excluded
  # entirely so `--outputfoo` is left alone.
  def test_native_unrelated_bundles_are_left_alone
    with_fake_home do |home|
      ok = File.join(home, 'legit.out')
      [["-o#{ok}"], ["-oo#{ok}"], ["-o=#{ok}"], ['-N2'], ['--nodes=4'],
       ['--exclusive']].each do |native|
        Handlers::Jobs.validate_native_paths!(native)
      end
    end
  end

  # Only path-bearing flags are inspected; everything else in native is a
  # legitimate scheduler option and must pass through untouched.
  def test_native_non_path_flags_are_left_alone
    with_fake_home do |home|
      [["--output=#{File.join(home, 'ok.out')}"], ['-o', File.join(home, 'ok.out')],
       ['--nodes=4'], ['-N', '2', '--exclusive'], ['--output'], [], nil].each do |native|
        Handlers::Jobs.validate_native_paths!(native)
      end
    end
  end

  include TestHelpers

  def setup
    @adapter = mock('adapter')
    @cluster = mock_cluster(id: 'cluster1')
    @cluster.stubs(:job_adapter).returns(@adapter)
    @clusters = [@cluster]
  end

  # list

  def test_list_returns_jobs_and_cluster
    @adapter.expects(:info_where_owner).with('drew').returns([mock_job_info(id: '123')])
    jobs, cluster = Handlers::Jobs.list(clusters: @clusters, cluster_id: 'cluster1', user: 'drew')
    assert_equal 1, jobs.size
    assert_equal '123', jobs[0].id
    assert_equal :cluster1, cluster.id
  end

  def test_list_raises_not_found_for_bad_cluster
    assert_raises(Handlers::NotFoundError) do
      Handlers::Jobs.list(clusters: @clusters, cluster_id: 'bad', user: 'drew')
    end
  end

  def test_list_raises_adapter_error_on_scheduler_failure
    @adapter.stubs(:info_where_owner).raises(OodCore::JobAdapterError, 'connection refused')
    assert_raises(Handlers::AdapterError) do
      Handlers::Jobs.list(clusters: @clusters, cluster_id: 'cluster1', user: 'drew')
    end
  end

  # historic

  def test_historic_returns_jobs_and_cluster
    @adapter.expects(:info_historic).with(opts: {}).returns([mock_job_info(id: '100'), mock_job_info(id: '101')])
    jobs, cluster = Handlers::Jobs.historic(clusters: @clusters, cluster_id: 'cluster1', user: 'testuser')
    assert_equal 2, jobs.size
    assert_equal '100', jobs[0].id
    assert_equal :cluster1, cluster.id
  end

  def test_historic_filters_by_user
    other_job = mock_job_info(id: '200', job_owner: 'otheruser')
    my_job = mock_job_info(id: '201', job_owner: 'drew')
    @adapter.stubs(:info_historic).returns([other_job, my_job])

    jobs, _cluster = Handlers::Jobs.historic(clusters: @clusters, cluster_id: 'cluster1', user: 'drew')
    assert_equal 1, jobs.size
    assert_equal '201', jobs[0].id
  end

  def test_historic_raises_not_found_for_bad_cluster
    assert_raises(Handlers::NotFoundError) do
      Handlers::Jobs.historic(clusters: @clusters, cluster_id: 'bad', user: 'drew')
    end
  end

  def test_historic_raises_adapter_error_on_scheduler_failure
    @adapter.stubs(:info_historic).raises(OodCore::JobAdapterError, 'not supported')
    assert_raises(Handlers::AdapterError) do
      Handlers::Jobs.historic(clusters: @clusters, cluster_id: 'cluster1', user: 'drew')
    end
  end

  # get

  def test_get_returns_job_and_cluster
    @adapter.expects(:info).with('456').returns(mock_job_info(id: '456'))
    job, cluster = Handlers::Jobs.get(clusters: @clusters, cluster_id: 'cluster1', job_id: '456')
    assert_equal '456', job.id
    assert_equal :cluster1, cluster.id
  end

  def test_get_raises_not_found_for_nil_job_id
    @adapter.stubs(:info).returns(OodCore::Job::Info.new(id:     nil,
                                                         status: OodCore::Job::Status.new(state: :undetermined)))
    assert_raises(Handlers::NotFoundError) do
      Handlers::Jobs.get(clusters: @clusters, cluster_id: 'cluster1', job_id: '999')
    end
  end

  # An unreachable scheduler must not be reported as a missing job. The adapter
  # signals "no such job" by returning Info(status: :completed), not by raising,
  # so a raise here means the scheduler could not answer at all.
  def test_get_raises_adapter_error_when_scheduler_is_unreachable
    @adapter.stubs(:info).raises(OodCore::JobAdapterError, 'Unable to contact slurm controller')
    assert_raises(Handlers::AdapterError) do
      Handlers::Jobs.get(clusters: @clusters, cluster_id: 'cluster1', job_id: '999')
    end
  end

  # Adapters echo the requested id back instead of signalling "no such job", so
  # an unknown id arrives as :completed with every other field nil — previously
  # served as a 200 with a fabricated completed job.
  def test_get_raises_not_found_for_unknown_id_echoed_back
    @adapter.stubs(:info).returns(
      OodCore::Job::Info.new(id: '99999', status: OodCore::Job::Status.new(state: :completed))
    )
    assert_raises(Handlers::NotFoundError) do
      Handlers::Jobs.get(clusters: @clusters, cluster_id: 'cluster1', job_id: '99999')
    end
  end

  # A job that genuinely ran carries an owner, so it must still be returned.
  def test_get_returns_a_real_completed_job
    @adapter.stubs(:info).returns(
      OodCore::Job::Info.new(id: '456', job_owner: 'alice',
                             status: OodCore::Job::Status.new(state: :completed))
    )
    job, = Handlers::Jobs.get(clusters: @clusters, cluster_id: 'cluster1', job_id: '456')
    assert_equal '456', job.id
    assert_equal 'alice', job.job_owner
  end

  # submit

  def test_submit_returns_job_info_and_cluster
    @adapter.expects(:submit).returns('789')
    @adapter.expects(:info).with('789').returns(mock_job_info(id: '789'))
    job_info, cluster = Handlers::Jobs.submit(
      clusters: @clusters, cluster_id: 'cluster1',
      script_content: "#!/bin/bash\necho hello"
    )
    assert_equal '789', job_info.id
    assert_equal :cluster1, cluster.id
  end

  # The wiring, not just the helper: a test that calls validate_native_paths!
  # directly still passes if the call is dropped from submit, which is exactly
  # the gap that let this bug exist. Go through the real entry point.
  def test_submit_refuses_a_denied_path_hidden_in_native
    with_fake_home do |home|
      denied = File.join(home, '.ssh', 'authorized_keys')

      # Default: native is disabled outright, so the request is refused before
      # the path is even considered.
      ENV.delete('OOD_API_ALLOW_NATIVE')
      assert_raises(Handlers::ValidationError, 'native must be refused when not enabled') do
        Handlers::Jobs.submit(clusters: @clusters, cluster_id: 'cluster1',
                              script_content: 'echo hi', workdir: home,
                              native: ["--output=#{denied}"])
      end

      # Opted in: the path check still runs as defence in depth.
      ENV['OOD_API_ALLOW_NATIVE'] = 'true'
      assert_raises(Handlers::ForbiddenError, 'submit must validate native paths') do
        Handlers::Jobs.submit(clusters: @clusters, cluster_id: 'cluster1',
                              script_content: 'echo hi', workdir: home,
                              native: ["--output=#{denied}"])
      end
    ensure
      ENV.delete('OOD_API_ALLOW_NATIVE')
    end
  end

  def test_submit_raises_validation_error_on_nil_content
    assert_raises(Handlers::ValidationError) do
      Handlers::Jobs.submit(clusters: @clusters, cluster_id: 'cluster1', script_content: nil)
    end
  end

  def test_submit_raises_validation_error_on_empty_content
    assert_raises(Handlers::ValidationError) do
      Handlers::Jobs.submit(clusters: @clusters, cluster_id: 'cluster1', script_content: '   ')
    end
  end

  def test_submit_raises_adapter_error_on_failure
    @adapter.stubs(:submit).raises(OodCore::JobAdapterError, 'queue full')
    assert_raises(Handlers::AdapterError) do
      Handlers::Jobs.submit(clusters: @clusters, cluster_id: 'cluster1', script_content: "#!/bin/bash\necho hi")
    end
  end

  def test_submit_passes_options_to_script
    @adapter.stubs(:submit).returns('100')
    @adapter.stubs(:info).returns(mock_job_info(id: '100'))
    Handlers::Jobs.submit(
      clusters: @clusters, cluster_id: 'cluster1',
      script_content: '#!/bin/bash',
      job_name: 'test-job', queue_name: 'batch',
      wall_time: 3600, accounting_id: 'myaccount'
    )
    assert true
  end

  def test_submit_passes_dependencies
    @adapter.expects(:submit).with do |_script, **kwargs|
      kwargs[:afterok] == ['100', '101'] && kwargs[:afterany] == ['200']
    end.returns('300')
    @adapter.stubs(:info).returns(mock_job_info(id: '300'))

    Handlers::Jobs.submit(
      clusters: @clusters, cluster_id: 'cluster1',
      script_content: '#!/bin/bash',
      afterok: ['100', '101'],
      afterany: ['200']
    )
  end

  # cancel / hold / release
  #
  # These three confirm the job exists before acting, because ood_core swallows
  # "Invalid job id specified" and returns normally for a job that is not there.
  # Stub `info` accordingly.

  def stub_existing_job(id = '789')
    @adapter.stubs(:info).with(id).returns(mock_job_info(id: id, job_owner: 'drew'))
  end

  # An id the scheduler has never heard of comes back as :completed with no
  # owner. Acting on it used to return 200 with a fabricated status.
  def stub_missing_job(id = '99999')
    @adapter.stubs(:info).with(id).returns(
      OodCore::Job::Info.new(id: id, status: OodCore::Job::Status.new(state: :completed))
    )
  end

  def test_cancel_raises_not_found_for_unknown_job
    stub_missing_job
    @adapter.expects(:delete).never
    assert_raises(Handlers::NotFoundError) do
      Handlers::Jobs.cancel(clusters: @clusters, cluster_id: 'cluster1', job_id: '99999')
    end
  end

  def test_hold_raises_not_found_for_unknown_job
    stub_missing_job
    @adapter.expects(:hold).never
    assert_raises(Handlers::NotFoundError) do
      Handlers::Jobs.hold(clusters: @clusters, cluster_id: 'cluster1', job_id: '99999')
    end
  end

  def test_release_raises_not_found_for_unknown_job
    stub_missing_job
    @adapter.expects(:release).never
    assert_raises(Handlers::NotFoundError) do
      Handlers::Jobs.release(clusters: @clusters, cluster_id: 'cluster1', job_id: '99999')
    end
  end

  def test_cancel_calls_delete_on_adapter
    stub_existing_job
    @adapter.expects(:delete).with('789')
    result = Handlers::Jobs.cancel(clusters: @clusters, cluster_id: 'cluster1', job_id: '789')
    assert_equal '789', result[:job_id]
    assert_equal 'cancelled', result[:status]
  end

  def test_cancel_raises_adapter_error_on_failure
    stub_existing_job
    @adapter.stubs(:delete).raises(OodCore::JobAdapterError, 'permission denied')
    assert_raises(Handlers::AdapterError) do
      Handlers::Jobs.cancel(clusters: @clusters, cluster_id: 'cluster1', job_id: '789')
    end
  end

  # hold

  def test_hold_calls_hold_on_adapter
    stub_existing_job
    @adapter.expects(:hold).with('789')
    result = Handlers::Jobs.hold(clusters: @clusters, cluster_id: 'cluster1', job_id: '789')
    assert_equal '789', result[:job_id]
    assert_equal 'queued_held', result[:status]
  end

  def test_hold_raises_adapter_error_on_failure
    stub_existing_job
    @adapter.stubs(:hold).raises(OodCore::JobAdapterError, 'cannot hold')
    assert_raises(Handlers::AdapterError) do
      Handlers::Jobs.hold(clusters: @clusters, cluster_id: 'cluster1', job_id: '789')
    end
  end

  # release

  def test_release_calls_release_on_adapter
    stub_existing_job
    @adapter.expects(:release).with('789')
    result = Handlers::Jobs.release(clusters: @clusters, cluster_id: 'cluster1', job_id: '789')
    assert_equal '789', result[:job_id]
    assert_equal 'queued', result[:status]
  end

  def test_release_raises_adapter_error_on_failure
    stub_existing_job
    @adapter.stubs(:release).raises(OodCore::JobAdapterError, 'cannot release')
    assert_raises(Handlers::AdapterError) do
      Handlers::Jobs.release(clusters: @clusters, cluster_id: 'cluster1', job_id: '789')
    end
  end

  # An outage and a rejected request are different problems: one is not the
  # caller's to fix. They used to be the same AdapterError, so the same
  # slurmctld outage gave 503 on a read and 422 on a write.
  def test_unreachable_scheduler_raises_scheduler_unavailable
    @adapter.stubs(:submit).raises(
      OodCore::JobAdapterError, 'slurm_load_jobs error: Unable to contact slurm controller (connect failure)'
    )
    assert_raises(Handlers::SchedulerUnavailableError) do
      Handlers::Jobs.submit(clusters: @clusters, cluster_id: 'cluster1', script_content: '#!/bin/bash')
    end
  end

  # A rejection must stay an ordinary AdapterError, not be promoted to 503.
  def test_rejected_request_stays_an_adapter_error
    @adapter.stubs(:submit).raises(OodCore::JobAdapterError, 'sbatch: error: invalid partition specified: nope')
    err = assert_raises(Handlers::AdapterError) do
      Handlers::Jobs.submit(clusters: @clusters, cluster_id: 'cluster1', script_content: '#!/bin/bash')
    end
    refute_kind_of Handlers::SchedulerUnavailableError, err
  end
end
