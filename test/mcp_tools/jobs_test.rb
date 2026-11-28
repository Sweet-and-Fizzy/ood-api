# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/mcp_tools/jobs'

class ListJobsToolTest < Minitest::Test
  include OodApi::Tools
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::SiteClusters.stubs(:all).returns(@clusters)
  end

  def test_lists_jobs
    jobs = [
      mock_job_info(id: '123', job_name: 'sim1', status: :running),
      mock_job_info(id: '456', job_name: 'sim2', status: :queued)
    ]
    adapter = mock('adapter')
    adapter.stubs(:info_where_owner).returns(jobs)
    @cluster.stubs(:job_adapter).returns(adapter)

    result = ListJobsTool.call(server_context: nil, cluster_id: 'cluster1')
    content = result.to_h
    refute content[:isError]
    text = content[:content].first[:text]
    assert_includes text, '2 job(s)'
    assert_includes text, '123'
    assert_includes text, 'sim1'
  end

  def test_a_waiting_job_says_why_and_when_it_should_start
    saved = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'UTC'
    jobs = [
      mock_job_info(id: '13', job_name: 'long-fit', status: :queued,
                    native: { reason: 'BeginTime', start_time: '2026-11-28T20:59:35' }),
      mock_job_info(id: '14', job_name: 'held', status: :queued_held,
                    native: { reason: 'JobHeldUser', start_time: 'N/A' }),
      mock_job_info(id: '15', job_name: 'now', status: :running, native: { reason: 'None' })
    ]
    adapter = mock('adapter')
    adapter.stubs(:info_where_owner).returns(jobs)
    @cluster.stubs(:job_adapter).returns(adapter)

    text = ListJobsTool.call(server_context: nil, cluster_id: 'cluster1').to_h[:content].first[:text]
    assert_includes text,
                    '- 13: long-fit [queued] queue=batch reason=BeginTime, expected start 2026-11-28T20:59:35+00:00'
    assert_includes text, '- 14: held [queued_held] queue=batch reason=JobHeldUser'
    refute_match(/15: now .*reason/, text)
  ensure
    saved ? ENV['TZ'] = saved : ENV.delete('TZ')
  end

  def test_empty_jobs
    adapter = mock('adapter')
    adapter.stubs(:info_where_owner).returns([])
    @cluster.stubs(:job_adapter).returns(adapter)

    result = ListJobsTool.call(server_context: nil, cluster_id: 'cluster1')
    text = result.to_h[:content].first[:text]
    assert_includes text, 'No jobs found'
  end

  def test_error_on_missing_cluster
    result = ListJobsTool.call(server_context: nil, cluster_id: 'nonexistent')
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'Cluster not found'
  end

  def test_a_finished_job_shows_the_schedulers_word_after_completed
    jobs = [
      mock_job_info(id: '13', job_name: 'growth', status: :completed, native: { state: 'FAILED' }),
      mock_job_info(id: '15', job_name: 'fit', status: :running, native: { state: 'RUNNING' })
    ]
    adapter = mock('adapter')
    adapter.stubs(:info_where_owner).returns(jobs)
    @cluster.stubs(:job_adapter).returns(adapter)

    text = ListJobsTool.call(server_context: nil, cluster_id: 'cluster1').content.first[:text]

    assert_includes text, '- 13: growth [completed (failed)]'
    assert_includes text, '- 15: fit [running]'
  end
end

class GetJobToolTest < Minitest::Test
  include OodApi::Tools
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::SiteClusters.stubs(:all).returns(@clusters)
  end

  def test_gets_job
    job = mock_job_info(id: '123', job_name: 'sim1', status: :running, job_owner: 'drew')
    adapter = mock('adapter')
    adapter.stubs(:info).with('123').returns(job)
    @cluster.stubs(:job_adapter).returns(adapter)

    result = GetJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '123')
    content = result.to_h
    refute content[:isError]
    text = content[:content].first[:text]
    assert_includes text, '123'
    assert_includes text, 'sim1'
    assert_includes text, 'drew'
  end

  def test_error_on_missing_job
    job = OodCore::Job::Info.new(id: nil, status: OodCore::Job::Status.new(state: :undetermined))
    adapter = mock('adapter')
    adapter.stubs(:info).with('999').returns(job)
    @cluster.stubs(:job_adapter).returns(adapter)

    result = GetJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '999')
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'Job not found'
  end

  def test_a_running_job_shows_how_long_it_has_run_against_its_limit
    job = mock_job_info(id: '17', status: :running, wallclock_time: 4034, wallclock_limit: 28_800,
                        native: { state: 'RUNNING' })
    adapter = mock('adapter')
    adapter.stubs(:info).returns(job)
    @cluster.stubs(:job_adapter).returns(adapter)

    text = GetJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '17').content.first[:text]

    assert_match(/^Run time so far: 1h 07m 14s$/, text)
    assert_match(/^Time limit: 8h 00m 00s$/, text)
    assert_match(/^Time left: 6h 52m 46s$/, text)
    assert_match(/^Checked at: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}([+-]\d{2}:\d{2}|Z)$/, text)
    refute_match(/Wall time/, text)
  end

  # Times are given in the local zone (TZ when the caller sets it) with
  # their offset, so a reader never has to convert them.
  def test_times_are_in_the_local_zone_with_their_offset
    saved = ENV.fetch('TZ', nil)
    ENV['TZ'] = 'America/New_York'
    utc = Time.utc(2026, 11, 25, 19, 0, 0)
    job = mock_job_info(id: '17', status: :running, submission_time: utc, dispatch_time: utc + 60)
    adapter = mock('adapter')
    adapter.stubs(:info).returns(job)
    @cluster.stubs(:job_adapter).returns(adapter)

    text = GetJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '17').content.first[:text]

    assert_match(/^Submitted: 2026-11-25T14:00:00-05:00$/, text)
    assert_match(/^Started: 2026-11-25T14:01:00-05:00$/, text)
    assert_match(/^Checked at: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}-0[45]:00$/, text)
  ensure
    saved ? ENV['TZ'] = saved : ENV.delete('TZ')
  end

  def test_a_waiting_job_has_not_started_whatever_its_dispatch_time_says
    estimate = Time.utc(2026, 11, 26, 0, 41)
    job = mock_job_info(id: '22', status: :queued, dispatch_time: estimate,
                        native: { state: 'PENDING', start_time: estimate.getlocal.strftime('%Y-%m-%dT%H:%M:%S') })
    adapter = mock('adapter')
    adapter.stubs(:info).returns(job)
    @cluster.stubs(:job_adapter).returns(adapter)

    text = GetJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '22').content.first[:text]

    assert_match(%r{^Started: N/A$}, text)
    assert_match(/^Expected start: #{Regexp.escape(estimate.getlocal.iso8601)}$/, text)
  end

  def test_a_job_shows_the_nodes_cores_gpus_and_memory_it_asked_for
    job = mock_job_info(id: '22', status: :queued, procs: 8, gpus: 1,
                        allocated_nodes: [OodCore::Job::NodeInfo.new(name: nil)],
                        native: { state: 'PENDING', min_memory: '16G' })
    adapter = mock('adapter')
    adapter.stubs(:info).returns(job)
    @cluster.stubs(:job_adapter).returns(adapter)

    text = GetJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '22').content.first[:text]

    assert_match(/^Resources: 1 node, 8 CPUs, 1 GPU$/, text)
    assert_match(/^Memory requested: 16G \(per node, or per CPU if the job asked for memory per CPU\)$/, text)
  end

  def test_gpus_on_several_nodes_are_per_node
    nodes = Array.new(2) { OodCore::Job::NodeInfo.new(name: nil) }
    job = mock_job_info(id: '24', status: :queued, procs: 16, gpus: 2, allocated_nodes: nodes)
    adapter = mock('adapter')
    adapter.stubs(:info).returns(job)
    @cluster.stubs(:job_adapter).returns(adapter)

    text = GetJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '24').content.first[:text]

    assert_match(/^Resources: 2 nodes, 16 CPUs, 2 GPUs per node$/, text)
  end

  def test_no_gpus_and_no_memory_are_left_out
    job = mock_job_info(id: '23', status: :running, procs: 2, gpus: 0, native: { min_memory: '0' })
    adapter = mock('adapter')
    adapter.stubs(:info).returns(job)
    @cluster.stubs(:job_adapter).returns(adapter)

    text = GetJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '23').content.first[:text]

    assert_match(/^Resources: 2 CPUs$/, text)
    refute_match(/GPU|^Memory/, text)
  end

  def test_a_failed_slurm_job_shows_the_schedulers_state_reason_and_output_file
    job = mock_job_info(id: '13', job_name: 'growth', status: :completed,
                        native: { state: 'FAILED', reason: 'NonZeroExitCode', work_dir: '/home/u/project' })
    adapter = mock('adapter')
    adapter.stubs(:info).returns(job)
    @cluster.stubs(:job_adapter).returns(adapter)

    text = GetJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '13').content.first[:text]

    assert_match(/^Status: completed$/, text)
    assert_match(/^Scheduler state: failed$/, text)
    assert_match(/^Reason: NonZeroExitCode$/, text)
    assert_match(%r{^Working directory: /home/u/project$}, text)
    assert_match(%r{^Output file: /home/u/project/slurm-13\.out \(Slurm default\)$}, text)
  end
end

class ListHistoricJobsToolTest < Minitest::Test
  include OodApi::Tools
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::SiteClusters.stubs(:all).returns(@clusters)
  end

  def test_lists_historic_jobs
    jobs = [
      mock_job_info(id: '100', job_name: 'old_sim', status: :completed, job_owner: ENV.fetch('USER', nil)),
      mock_job_info(id: '101', job_name: 'old_sim2', status: :completed, job_owner: ENV.fetch('USER', nil))
    ]
    adapter = mock('adapter')
    adapter.stubs(:info_historic).returns(jobs)
    @cluster.stubs(:job_adapter).returns(adapter)

    result = ListHistoricJobsTool.call(server_context: nil, cluster_id: 'cluster1')
    content = result.to_h
    refute content[:isError]
    text = content[:content].first[:text]
    assert_includes text, '2 historic job(s)'
    assert_includes text, '100'
    assert_includes text, 'old_sim'
  end

  def test_shows_how_each_job_ended_and_its_memory
    jobs = [
      mock_job_info(id: '200', job_name: 'fit', status: :completed, job_owner: ENV.fetch('USER', nil),
                    native: { state: 'OUT_OF_MEMORY', req_mem: '4G', max_rss: '', elapsed: '00:12:03' }),
      mock_job_info(id: '201', job_name: 'plot', status: :completed, job_owner: ENV.fetch('USER', nil))
    ]
    adapter = mock('adapter')
    adapter.stubs(:info_historic).returns(jobs)
    @cluster.stubs(:job_adapter).returns(adapter)

    text = ListHistoricJobsTool.call(server_context: nil, cluster_id: 'cluster1').to_h[:content].first[:text]
    assert_includes text, '- 200: fit [OUT_OF_MEMORY, memory requested 4G, ran for 00:12:03]'
    assert_includes text, '- 201: plot [completed]'
  end

  def test_shows_the_most_memory_a_job_used_from_its_steps
    user = ENV.fetch('USER', nil)
    rows = [
      mock_job_info(id: '300', job_name: 'growth-fit', status: :completed, job_owner: user,
                    native: { state: 'COMPLETED', req_mem: '0.59G', max_rss: nil, elapsed: '00:00:25', user: user }),
      mock_job_info(id: '300.batch', status: :completed, native: { state: 'COMPLETED', max_rss: '0.20G' })
    ]
    adapter = mock('adapter')
    adapter.stubs(:info_historic).returns(rows)
    @cluster.stubs(:job_adapter).returns(adapter)

    text = ListHistoricJobsTool.call(server_context: nil, cluster_id: 'cluster1').to_h[:content].first[:text]
    assert_includes text, '1 historic job(s)'
    assert_includes text,
                    '- 300: growth-fit [COMPLETED, memory requested 0.59G, most memory used 0.20G, ran for 00:00:25]'
  end

  def test_a_cluster_with_no_accounting_is_a_clear_tool_error
    adapter = mock('adapter')
    adapter.stubs(:info_historic).raises(OodCore::JobAdapterError, 'Slurm accounting storage is disabled')
    @cluster.stubs(:job_adapter).returns(adapter)

    content = ListHistoricJobsTool.call(server_context: nil, cluster_id: 'cluster1').to_h
    assert content[:isError]
    assert_match(/keeps no record of finished jobs/, content[:content].first[:text])
  end

  def test_error_on_missing_cluster
    result = ListHistoricJobsTool.call(server_context: nil, cluster_id: 'nonexistent')
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'Cluster not found'
  end
end

class SubmitJobToolTest < Minitest::Test
  include OodApi::Tools
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::SiteClusters.stubs(:all).returns(@clusters)
  end

  def test_submits_job
    job = mock_job_info(id: '789', status: :queued)
    adapter = mock('adapter')
    adapter.stubs(:submit).returns('789')
    adapter.stubs(:info).with('789').returns(job)
    @cluster.stubs(:job_adapter).returns(adapter)

    result = SubmitJobTool.call(
      server_context: nil,
      cluster_id:     'cluster1',
      script_content: '#!/bin/bash\necho hello'
    )
    content = result.to_h
    refute content[:isError]
    text = content[:content].first[:text]
    assert_includes text, '789'
    assert_includes text, 'submitted successfully'
  end

  def test_error_on_empty_script
    result = SubmitJobTool.call(
      server_context: nil,
      cluster_id:     'cluster1',
      script_content: ''
    )
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'cannot be empty'
  end
end

class CancelJobToolTest < Minitest::Test
  include OodApi::Tools
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::SiteClusters.stubs(:all).returns(@clusters)
  end

  def test_cancels_job
    adapter = mock('adapter')
    adapter.stubs(:info).with('123').returns(mock_job_info(id: '123', job_owner: 'drew'))
    adapter.stubs(:delete).with('123')
    @cluster.stubs(:job_adapter).returns(adapter)

    result = CancelJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '123')
    content = result.to_h
    refute content[:isError]
    text = content[:content].first[:text]
    assert_includes text, '123'
    assert_includes text, 'cancelled'
  end

  def test_error_on_missing_cluster
    OodApi::SiteClusters.stubs(:all).returns([])

    result = CancelJobTool.call(cluster_id: 'bad', job_id: '123', server_context: nil)
    content = result.to_h
    assert content[:isError]
  end
end

class HoldJobToolTest < Minitest::Test
  include OodApi::Tools
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::SiteClusters.stubs(:all).returns(@clusters)
  end

  def test_holds_job
    adapter = mock('adapter')
    adapter.stubs(:info).with('123').returns(mock_job_info(id: '123', job_owner: 'drew'))
    adapter.stubs(:hold).with('123')
    @cluster.stubs(:job_adapter).returns(adapter)

    result = HoldJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '123')
    content = result.to_h
    refute content[:isError]
    text = content[:content].first[:text]
    assert_includes text, '123'
    assert_includes text, 'held'
  end

  # Each tool used to list the handler errors it expected, and the lists had
  # drifted: hold_job omitted ForbiddenError, so that one error escaped as a
  # protocol-level internal error. Every handler error is now a tool error.
  def test_any_handler_error_is_a_tool_error
    [Handlers::ForbiddenError, Handlers::StorageError, Handlers::PayloadTooLargeError].each do |error|
      Handlers::Jobs.stubs(:hold).raises(error, 'refused')

      content = HoldJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '123').to_h

      assert content[:isError], "#{error} must be reported as a tool error"
      assert_equal 'refused', content[:content].first[:text]
    end
  end

  def test_error_on_missing_cluster
    OodApi::SiteClusters.stubs(:all).returns([])

    result = HoldJobTool.call(cluster_id: 'bad', job_id: '123', server_context: nil)
    content = result.to_h
    assert content[:isError]
  end
end

class ReleaseJobToolTest < Minitest::Test
  include OodApi::Tools
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::SiteClusters.stubs(:all).returns(@clusters)
  end

  def test_releases_job
    adapter = mock('adapter')
    adapter.stubs(:info).with('123').returns(mock_job_info(id: '123', job_owner: 'drew'))
    adapter.stubs(:release).with('123')
    @cluster.stubs(:job_adapter).returns(adapter)

    result = ReleaseJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '123')
    content = result.to_h
    refute content[:isError]
    text = content[:content].first[:text]
    assert_includes text, '123'
    assert_includes text, 'released'
  end

  def test_error_on_missing_cluster
    OodApi::SiteClusters.stubs(:all).returns([])

    result = ReleaseJobTool.call(cluster_id: 'bad', job_id: '123', server_context: nil)
    content = result.to_h
    assert content[:isError]
  end

  # hold and release omitted ValidationError from their rescue lists while all
  # five sibling job tools include it, so a bad job id escaped as a JSON-RPC
  # internal error instead of a clean tool error. REST returns 400 here.
  def test_hold_and_release_report_a_bad_job_id_as_a_tool_error
    @mock_clusters = [mock_cluster(id: 'cluster1')]
    OodApi::SiteClusters.stubs(:all).returns(@mock_clusters)
    bad = (+"job\xFF").force_encoding('UTF-8')

    [OodApi::Tools::HoldJobTool, OodApi::Tools::ReleaseJobTool].each do |tool|
      result = tool.call(server_context: nil, cluster_id: 'cluster1', job_id: bad)
      assert result.error?, "#{tool} must return a tool error, not raise"
    end
  end
end
