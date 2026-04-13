# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/mcp_tools/clusters'

class ListClustersToolTest < Minitest::Test
  include TestHelpers

  def setup
    @clusters = [mock_cluster(id: 'cluster1'), mock_cluster(id: 'cluster2', title: 'Cluster Two')]
    OodApi::App.stubs(:clusters).returns(@clusters)
  end

  def test_lists_clusters
    result = ListClustersTool.call(server_context: nil)
    content = result.to_h
    refute content[:isError]
    text = content[:content].first[:text]
    assert_includes text, 'cluster1'
    assert_includes text, 'cluster2'
    assert_includes text, '2 cluster(s)'
  end

  def test_shows_cluster_details
    result = ListClustersTool.call(server_context: nil)
    text = result.to_h[:content].first[:text]
    assert_includes text, 'adapter=slurm'
    assert_includes text, 'login=login1.example.edu'
  end
end

class ListClustersToolErrorTest < Minitest::Test
  include TestHelpers

  def test_returns_error_on_adapter_error
    OodApi::App.stubs(:clusters).returns([])
    Handlers::Clusters.stubs(:list).raises(Handlers::AdapterError, 'Adapter connection failed')

    result = ListClustersTool.call(server_context: nil)
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'Adapter connection failed'
  end
end

class ListAccountsToolTest < Minitest::Test
  include TestHelpers

  def setup
    @adapter = mock('adapter')
    @cluster = mock_cluster(id: 'cluster1')
    @cluster.stubs(:job_adapter).returns(@adapter)
    OodApi::App.stubs(:clusters).returns([@cluster])
  end

  def test_returns_accounts
    account = OodCore::Job::AccountInfo.new(name: 'PAS1234', qos: ['normal'])
    @adapter.stubs(:accounts).returns([account])

    result = ListAccountsTool.call(server_context: nil, cluster_id: 'cluster1')
    refute result.to_h[:isError]
    assert_match(/PAS1234/, result.to_h[:content].first[:text])
  end

  def test_returns_error_for_missing_cluster
    OodApi::App.stubs(:clusters).returns([])
    result = ListAccountsTool.call(server_context: nil, cluster_id: 'bad')
    assert result.to_h[:isError]
  end
end

class ListQueuesToolTest < Minitest::Test
  include TestHelpers

  def setup
    @adapter = mock('adapter')
    @cluster = mock_cluster(id: 'cluster1')
    @cluster.stubs(:job_adapter).returns(@adapter)
    OodApi::App.stubs(:clusters).returns([@cluster])
  end

  def test_returns_queues
    queue = OodCore::Job::QueueInfo.new(name: 'batch')
    @adapter.stubs(:queues).returns([queue])

    result = ListQueuesTool.call(server_context: nil, cluster_id: 'cluster1')
    refute result.to_h[:isError]
    assert_match(/batch/, result.to_h[:content].first[:text])
  end

  def test_returns_error_for_missing_cluster
    OodApi::App.stubs(:clusters).returns([])
    result = ListQueuesTool.call(server_context: nil, cluster_id: 'bad')
    assert result.to_h[:isError]
  end
end

class GetClusterInfoToolTest < Minitest::Test
  include TestHelpers

  def setup
    @adapter = mock('adapter')
    @cluster = mock_cluster(id: 'cluster1')
    @cluster.stubs(:job_adapter).returns(@adapter)
    OodApi::App.stubs(:clusters).returns([@cluster])
  end

  def test_returns_cluster_info
    info = OodCore::Job::ClusterInfo.new(
      active_nodes: 10, total_nodes: 20,
      active_processors: 100, total_processors: 200,
      active_gpus: 4, total_gpus: 8
    )
    @adapter.stubs(:cluster_info).returns(info)

    result = GetClusterInfoTool.call(server_context: nil, cluster_id: 'cluster1')
    refute result.to_h[:isError]
    text = result.to_h[:content].first[:text]
    assert_includes text, 'Nodes: 10/20 active'
    assert_includes text, 'CPUs: 100/200 active'
    assert_includes text, 'GPUs: 4/8 active'
  end

  def test_returns_error_for_missing_cluster
    OodApi::App.stubs(:clusters).returns([])
    result = GetClusterInfoTool.call(server_context: nil, cluster_id: 'bad')
    assert result.to_h[:isError]
  end

  def test_returns_error_for_not_implemented
    @adapter.stubs(:cluster_info).raises(NotImplementedError, 'not supported')

    result = GetClusterInfoTool.call(server_context: nil, cluster_id: 'cluster1')
    assert result.to_h[:isError]
  end
end

class GetClusterToolTest < Minitest::Test
  include TestHelpers

  def setup
    @clusters = [mock_cluster(id: 'cluster1'), mock_cluster(id: 'cluster2')]
    OodApi::App.stubs(:clusters).returns(@clusters)
  end

  def test_gets_cluster_by_id
    result = GetClusterTool.call(server_context: nil, cluster_id: 'cluster1')
    content = result.to_h
    refute content[:isError]
    text = content[:content].first[:text]
    assert_includes text, 'cluster1'
    assert_includes text, 'Adapter: slurm'
  end

  def test_returns_error_for_missing_cluster
    result = GetClusterTool.call(server_context: nil, cluster_id: 'nonexistent')
    content = result.to_h
    assert content[:isError]
    assert_includes content[:content].first[:text], 'Cluster not found'
  end
end
