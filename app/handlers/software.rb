# frozen_string_literal: true

require 'json'
require 'pathname'
require_relative 'errors'
require_relative '../../lib/site_config'

module Handlers
  # Software installed as environment modules, as the Dashboard's Module
  # Browser lists it: one Lmod spider JSON file per cluster, named after the
  # cluster, in the site's module file directory. Hidden modules are left
  # out, as the Module Browser leaves them out.
  module Software
    NAME_LIMIT = 40

    Found = Struct.new(:name, :versions, keyword_init: true)
    Version = Struct.new(:cluster_id, :version, :prerequisites, keyword_init: true)

    module_function

    # Modules whose names contain `name` (any, when none is given), on one
    # cluster or every cluster that runs jobs, each with its versions newest
    # first.
    #
    # @return [Hash] :modules (Array<Found>), :more (names past the limit)
    def find(clusters:, name: nil, cluster_id: nil)
      dir = OodApi::SiteConfig.module_file_dir
      raise NotSupportedError, 'This site does not publish a list of its software modules' unless dir

      versions = matching(clusters_for(clusters, cluster_id).flat_map do |cluster|
        read(dir.join("#{cluster.id}.json"), cluster.id.to_s)
      end, name)
      grouped = versions.group_by { |v| v[:name] }.sort_by { |module_name, _| module_name.downcase }
      found = grouped.first(NAME_LIMIT).map do |module_name, list|
        Found.new(name: module_name, versions: newest_first(list).map { |v| v[:version] })
      end
      { modules: found, more: [grouped.size - NAME_LIMIT, 0].max }
    end

    def clusters_for(clusters, cluster_id)
      return clusters.select(&:job_allow?) if cluster_id.to_s.empty?

      found = clusters.select { |c| c.job_allow? && c.id.to_s == cluster_id.to_s }
      raise NotFoundError, "Cluster #{cluster_id} not found" if found.empty?

      found
    end

    # Names are compared without case or punctuation, so pytorch finds
    # py-torch and PyTorch finds both.
    def matching(versions, name)
      query = plain(name)
      query.empty? ? versions : versions.select { |v| plain(v[:name]).include?(query) }
    end

    def plain(text)
      text.to_s.downcase.gsub(/[^[:alnum:]]/, '')
    end

    # One cluster's spider output: { name => { modulefile => details } }.
    def read(file, cluster_id)
      data = JSON.parse(file.read(encoding: 'UTF-8'))
      return [] unless data.is_a?(Hash)

      data.flat_map do |name, files|
        next [] unless files.is_a?(Hash)

        files.values.select { |m| m.is_a?(Hash) && !m['hidden'] }.map do |m|
          version = Version.new(cluster_id: cluster_id, version: m['Version'].to_s,
                                prerequisites: prerequisites(m['parentAA']))
          { name: name.to_s, version: version }
        end
      end
    rescue SystemCallError, JSON::ParserError, EncodingError
      []
    end

    # Lmod's parentAA: the sets of modules, any one of which must be loaded
    # first, as `name/version` strings.
    def prerequisites(parents)
      return [] unless parents.is_a?(Array)

      parents.grep(Array).map { |set| set.map(&:to_s) }
    end

    def newest_first(list)
      list.sort_by { |v| sortable(v[:version].version) }.reverse
          .uniq { |v| [v[:version].cluster_id, v[:version].version] }
    end

    def sortable(version)
      [1, Gem::Version.new(version)]
    rescue ArgumentError
      [0, version]
    end
  end
end
