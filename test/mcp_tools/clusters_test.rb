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
