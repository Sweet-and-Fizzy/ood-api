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
    assert_match(/^Checked at: \d{4}-\d{2}-\d{2}T/, text)
    refute_match(/Wall time/, text)
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
