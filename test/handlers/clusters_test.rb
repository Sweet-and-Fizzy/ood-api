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
end
