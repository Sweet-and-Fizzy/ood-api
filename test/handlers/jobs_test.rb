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
end
