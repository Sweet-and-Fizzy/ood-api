# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/jobs'

class HandlersJobsTest < Minitest::Test
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

  # get

  def test_get_returns_job_and_cluster
    @adapter.expects(:info).with('456').returns(mock_job_info(id: '456'))
    job, cluster = Handlers::Jobs.get(clusters: @clusters, cluster_id: 'cluster1', job_id: '456')
    assert_equal '456', job.id
    assert_equal :cluster1, cluster.id
  end

  def test_get_raises_not_found_for_nil_job_id
    @adapter.stubs(:info).returns(OodCore::Job::Info.new(id: nil, status: OodCore::Job::Status.new(state: :undetermined)))
    assert_raises(Handlers::NotFoundError) do
      Handlers::Jobs.get(clusters: @clusters, cluster_id: 'cluster1', job_id: '999')
    end
  end

  def test_get_raises_not_found_on_adapter_error
    @adapter.stubs(:info).raises(OodCore::JobAdapterError, 'not found')
    assert_raises(Handlers::NotFoundError) do
      Handlers::Jobs.get(clusters: @clusters, cluster_id: 'cluster1', job_id: '999')
    end
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

  # cancel

  def test_cancel_calls_delete_on_adapter
    @adapter.expects(:delete).with('789')
    result = Handlers::Jobs.cancel(clusters: @clusters, cluster_id: 'cluster1', job_id: '789')
    assert_equal '789', result[:job_id]
    assert_equal 'cancelled', result[:status]
  end

  def test_cancel_raises_adapter_error_on_failure
    @adapter.stubs(:delete).raises(OodCore::JobAdapterError, 'permission denied')
    assert_raises(Handlers::AdapterError) do
      Handlers::Jobs.cancel(clusters: @clusters, cluster_id: 'cluster1', job_id: '789')
    end
  end
end
