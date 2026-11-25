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
    # first. An exact match comes first, then names that start with `name`,
    # so a short name is not lost among the names that merely contain it.
    #
    # @return [Hash] :modules (Array<Found>), :more (names past the limit),
    #   :unlisted (ids of clusters with no readable module list)
    def find(clusters:, name: nil, cluster_id: nil)
      dir = OodApi::SiteConfig.module_file_dir
      raise NotSupportedError, 'This site does not publish a list of its software modules' unless dir

      lists = lists(dir, clusters_for(clusters, cluster_id))
      grouped = matching(lists.values.compact.flatten, name).group_by { |v| v[:name] }
      ranked = grouped.sort_by { |module_name, _| [rank(module_name, name), module_name.downcase] }
      found = ranked.first(NAME_LIMIT).map do |module_name, list|
        Found.new(name: module_name, versions: newest_first(list).map { |v| v[:version] })
      end
      { modules: found, more: [ranked.size - NAME_LIMIT, 0].max, unlisted: lists.select { |_, v| v.nil? }.keys }
    end

    # Each cluster's modules by its id; nil for a cluster with no readable list.
    def lists(dir, clusters)
      clusters.to_h { |cluster| [cluster.id.to_s, cached(dir.join("#{cluster.id}.json"), cluster.id.to_s)] }
    end

    def rank(module_name, name)
      query = plain(name)
      candidate = plain(module_name)
      return 0 if candidate == query
      return 1 if candidate.start_with?(query)

      2
    end

    CACHE_LOCK = Mutex.new
    @cache = {}

    # A cluster's modules, parsed once for each version of its file: spider
    # files run to tens of megabytes at large sites. nil when the file cannot
    # be read.
    def cached(file, cluster_id)
      stat = file.stat
      key = [file.to_s, stat.mtime.to_r, stat.size]
      CACHE_LOCK.synchronize do
        @cache.delete_if { |k, _| k.first == key.first && k != key }
        @cache[key] ||= read(file, cluster_id)
      end
    rescue SystemCallError
      nil
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
    # nil when the file cannot be read or is not spider output.
    def read(file, cluster_id)
      data = JSON.parse(file.read(encoding: 'UTF-8'))
      return nil unless data.is_a?(Hash)

      data.flat_map do |name, files|
        next [] unless files.is_a?(Hash)

        files.values.select { |m| m.is_a?(Hash) && !m['hidden'] }.map do |m|
          version = Version.new(cluster_id: cluster_id, version: m['Version'].to_s,
                                prerequisites: prerequisites(m['parentAA']))
          { name: name.to_s, version: version }
        end
      end
    rescue SystemCallError, JSON::ParserError, EncodingError
      nil
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

    # Versions compare piece by piece, numbers as numbers and the rest as
    # text, so 3.10 follows 3.9, R2024a follows R2023b and 11.8.0-gcc
    # follows 11.8.0.
    def sortable(version)
      version.to_s.scan(/\d+|\D+/).map { |part| part.match?(/\A\d/) ? [0, part.to_i] : [1, part] }
    end
  end
end
