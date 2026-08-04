# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/clusters'

class HandlersClustersTest < Minitest::Test
  include TestHelpers

  def setup
    @clusters = [mock_cluster(id: 'cluster1'), mock_cluster(id: 'cluster2', title: 'Cluster Two')]
  end

  def test_list_returns_job_allowed_clusters
    result = Handlers::Clusters.list(clusters: @clusters)
    assert_equal 2, result.size
    assert_equal :cluster1, result[0].id
    assert_equal :cluster2, result[1].id
  end

  def test_list_filters_out_non_job_clusters
    @clusters[1].stubs(:job_allow?).returns(false)
    result = Handlers::Clusters.list(clusters: @clusters)
    assert_equal 1, result.size
    assert_equal :cluster1, result[0].id
  end

  def test_get_returns_cluster_by_id
    result = Handlers::Clusters.get(clusters: @clusters, id: 'cluster1')
    assert_equal :cluster1, result.id
  end

  def test_get_raises_not_found_for_missing_cluster
    assert_raises(Handlers::NotFoundError) do
      Handlers::Clusters.get(clusters: @clusters, id: 'nonexistent')
    end
  end

  def test_get_raises_not_found_for_non_job_cluster
    @clusters[0].stubs(:job_allow?).returns(false)
    assert_raises(Handlers::NotFoundError) do
      Handlers::Clusters.get(clusters: @clusters, id: 'cluster1')
    end
  end

  def test_accounts_returns_accounts_for_cluster
    account = OodCore::Job::AccountInfo.new(name: 'PAS1234', qos: ['normal', 'standby'], cluster: 'cluster1')
    adapter = mock('adapter')
    adapter.expects(:accounts).returns([account])
    @clusters[0].stubs(:job_adapter).returns(adapter)

    result = Handlers::Clusters.accounts(clusters: @clusters, id: 'cluster1')
    assert_equal 1, result.size
    assert_equal 'PAS1234', result[0].name
  end

  def test_accounts_raises_not_found_for_bad_cluster
    assert_raises(Handlers::NotFoundError) do
      Handlers::Clusters.accounts(clusters: @clusters, id: 'nonexistent')
    end
  end

  def test_queues_returns_queues_for_cluster
    queue = OodCore::Job::QueueInfo.new(name: 'batch')
    adapter = mock('adapter')
    adapter.expects(:queues).returns([queue])
    @clusters[0].stubs(:job_adapter).returns(adapter)

    result = Handlers::Clusters.queues(clusters: @clusters, id: 'cluster1')
    assert_equal 1, result.size
    assert_equal 'batch', result[0].name
  end

  def test_queues_raises_not_found_for_bad_cluster
    assert_raises(Handlers::NotFoundError) do
      Handlers::Clusters.queues(clusters: @clusters, id: 'nonexistent')
    end
  end

  def test_info_returns_cluster_info
    info = OodCore::Job::ClusterInfo.new(
      active_nodes: 10, total_nodes: 20,
      active_processors: 100, total_processors: 200,
      active_gpus: 4, total_gpus: 8
    )
    adapter = mock('adapter')
    adapter.expects(:cluster_info).returns(info)
    @clusters[0].stubs(:job_adapter).returns(adapter)

    result = Handlers::Clusters.info(clusters: @clusters, id: 'cluster1')
    assert_equal 10, result.active_nodes
    assert_equal 20, result.total_nodes
  end

  def test_info_raises_not_found_for_bad_cluster
    assert_raises(Handlers::NotFoundError) do
      Handlers::Clusters.info(clusters: @clusters, id: 'nonexistent')
    end
  end

  def test_info_raises_not_supported_for_not_implemented
    adapter = mock('adapter')
    adapter.expects(:cluster_info).raises(NotImplementedError, 'not supported')
    @clusters[0].stubs(:job_adapter).returns(adapter)

    assert_raises(Handlers::NotSupportedError) do
      Handlers::Clusters.info(clusters: @clusters, id: 'cluster1')
    end
  end

  # Adapters raise their own error classes that do NOT descend from
  # OodCore::JobAdapterError — e.g. OodCore::Job::Adapters::Slurm::Batch::Error,
  # which derives straight from StandardError. Before with_adapter these
  # escaped as unhandled 500s.
  def test_accounts_wraps_adapter_specific_error
    adapter_error = Class.new(StandardError)
    adapter = mock('adapter')
    adapter.expects(:accounts).raises(adapter_error, 'sacctmgr failed')
    @clusters[0].stubs(:job_adapter).returns(adapter)

    error = assert_raises(Handlers::AdapterError) do
      Handlers::Clusters.accounts(clusters: @clusters, id: 'cluster1')
    end
    assert_match(/sacctmgr failed/, error.message)
  end

  # Scheduler stderr is arbitrary bytes, and unavailable? matched patterns
  # against it raw. Regexp#match? raises ArgumentError on invalid UTF-8, so a
  # malformed byte in the scheduler's own message turned a clean 503 into a
  # 500 from inside the error path itself.
  def test_adapter_message_with_invalid_utf8_still_classifies
    adapter_error = Class.new(StandardError)
    adapter = mock('adapter')
    adapter.expects(:accounts).raises(adapter_error, (+"Connection refused \xFF").force_encoding('UTF-8'))
    @clusters[0].stubs(:job_adapter).returns(adapter)

    # "connection refused" is an unavailability pattern, so this must come back
    # as the 503-mapped error rather than raising ArgumentError.
    assert_raises(Handlers::SchedulerUnavailableError) do
      Handlers::Clusters.accounts(clusters: @clusters, id: 'cluster1')
    end
  end

  def test_queues_raises_not_supported_for_not_implemented
    adapter = mock('adapter')
    adapter.expects(:queues).raises(NotImplementedError, 'no queues')
    @clusters[0].stubs(:job_adapter).returns(adapter)

    assert_raises(Handlers::NotSupportedError) do
      Handlers::Clusters.queues(clusters: @clusters, id: 'cluster1')
    end
  end

  # ood_core's base adapter returns [] for accounts and queues rather than
  # raising, so a PBS/LSF/SGE site got 200 [] where the docs promised 501 —
  # and no client could tell "no accounts" from "cannot answer".
  def test_accounts_reports_unsupported_when_the_adapter_inherits_the_base_no_op
    cluster = mock_cluster(id: 'pbs-like')
    cluster.stubs(:job_adapter).returns(OodCore::Job::Adapter.new)

    assert_raises(Handlers::NotSupportedError) do
      Handlers::Clusters.accounts(clusters: [cluster], id: 'pbs-like')
    end
  end

  def test_queues_reports_unsupported_when_the_adapter_inherits_the_base_no_op
    cluster = mock_cluster(id: 'pbs-like')
    cluster.stubs(:job_adapter).returns(OodCore::Job::Adapter.new)

    assert_raises(Handlers::NotSupportedError) do
      Handlers::Clusters.queues(clusters: [cluster], id: 'pbs-like')
    end
  end

  # An adapter that really implements these must still answer, including when
  # the honest answer is an empty list.
  def test_an_implementing_adapter_still_returns_its_empty_list
    adapter = Class.new(OodCore::Job::Adapter) do
      def accounts = []
      def queues = []
    end.new
    cluster = mock_cluster(id: 'slurm-like')
    cluster.stubs(:job_adapter).returns(adapter)

    assert_empty Handlers::Clusters.accounts(clusters: [cluster], id: 'slurm-like')
    assert_empty Handlers::Clusters.queues(clusters: [cluster], id: 'slurm-like')
  end
end
