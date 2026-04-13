# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/mcp_tools/jobs'

class ListJobsToolTest < Minitest::Test
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::App.stubs(:clusters).returns(@clusters)
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
end

class GetJobToolTest < Minitest::Test
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::App.stubs(:clusters).returns(@clusters)
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
end

class ListHistoricJobsToolTest < Minitest::Test
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::App.stubs(:clusters).returns(@clusters)
  end

  def test_lists_historic_jobs
    jobs = [
      mock_job_info(id: '100', job_name: 'old_sim', status: :completed, job_owner: ENV['USER']),
      mock_job_info(id: '101', job_name: 'old_sim2', status: :completed, job_owner: ENV['USER'])
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
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::App.stubs(:clusters).returns(@clusters)
  end

  def test_submits_job
    job = mock_job_info(id: '789', status: :queued)
    adapter = mock('adapter')
    adapter.stubs(:submit).returns('789')
    adapter.stubs(:info).with('789').returns(job)
    @cluster.stubs(:job_adapter).returns(adapter)

    result = SubmitJobTool.call(
      server_context: nil,
      cluster_id: 'cluster1',
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
      cluster_id: 'cluster1',
      script_content: ''
    )
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'cannot be empty'
  end
end

class CancelJobToolTest < Minitest::Test
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::App.stubs(:clusters).returns(@clusters)
  end

  def test_cancels_job
    adapter = mock('adapter')
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
    OodApi::App.stubs(:clusters).returns([])

    result = CancelJobTool.call(cluster_id: 'bad', job_id: '123', server_context: nil)
    content = result.to_h
    assert content[:isError]
  end
end

class HoldJobToolTest < Minitest::Test
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::App.stubs(:clusters).returns(@clusters)
  end

  def test_holds_job
    adapter = mock('adapter')
    adapter.stubs(:hold).with('123')
    @cluster.stubs(:job_adapter).returns(adapter)

    result = HoldJobTool.call(server_context: nil, cluster_id: 'cluster1', job_id: '123')
    content = result.to_h
    refute content[:isError]
    text = content[:content].first[:text]
    assert_includes text, '123'
    assert_includes text, 'held'
  end

  def test_error_on_missing_cluster
    OodApi::App.stubs(:clusters).returns([])

    result = HoldJobTool.call(cluster_id: 'bad', job_id: '123', server_context: nil)
    content = result.to_h
    assert content[:isError]
  end
end

class ReleaseJobToolTest < Minitest::Test
  include TestHelpers

  def setup
    @cluster = mock_cluster(id: 'cluster1')
    @clusters = [@cluster]
    OodApi::App.stubs(:clusters).returns(@clusters)
  end

  def test_releases_job
    adapter = mock('adapter')
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
    OodApi::App.stubs(:clusters).returns([])

    result = ReleaseJobTool.call(cluster_id: 'bad', job_id: '123', server_context: nil)
    content = result.to_h
    assert content[:isError]
  end
end
