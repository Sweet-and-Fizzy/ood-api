# frozen_string_literal: true

require_relative 'errors'

module Handlers
  module Clusters
    def self.list(clusters:)
      clusters.select(&:job_allow?)
    end

    def self.get(clusters:, id:)
      cluster = clusters.find { |c| c.id.to_s == id.to_s && c.job_allow? }
      raise NotFoundError, 'Cluster not found' unless cluster

      cluster
    end
  end
end
