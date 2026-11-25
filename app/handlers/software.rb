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

    # A cluster's modules, parsed once for each version of its file. nil when
    # the file cannot be read.
    #
    # Spider files run to tens of megabytes at large sites, and parsing one
    # grows a Ruby process by several times its size, which the process
    # keeps. Each user runs their own copy of this app, so the file is
    # parsed in a short-lived child process and only the modules come back;
    # what the parse used goes back to the system when the child exits.
    def cached(file, cluster_id)
      stat = file.stat
      key = [file.to_s, stat.mtime.to_r, stat.size]
      CACHE_LOCK.synchronize do
        @cache.delete_if { |k, _| k.first == key.first && k != key }
        @cache[key] ||= modules(in_child { spider(file) }, cluster_id)
      end
    rescue SystemCallError
      nil
    end

    # The block's result, as JSON, worked out in a forked child where forking
    # is available. The child sends back nothing but the result, and leaves
    # with exit! so no exit handler of this app runs in it. nil when the
    # child gives no result.
    def in_child
      return yield unless Process.respond_to?(:fork)

      reader, writer = IO.pipe
      pid = fork do
        reader.close
        writer.write(JSON.generate(yield))
      ensure
        writer.close
        exit!(0)
      end
      writer.close
      begin
        JSON.parse(reader.read)
      rescue JSON::ParserError
        nil
      ensure
        reader.close
        Process.wait(pid)
      end
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

    # One cluster's spider output, { name => { modulefile => details } },
    # cut down to [name, version, prerequisites] for each module that is not
    # hidden. nil when the file cannot be read or is not spider output.
    def spider(file)
      data = JSON.parse(file.read(encoding: 'UTF-8'))
      return nil unless data.is_a?(Hash)

      data.flat_map do |name, files|
        next [] unless files.is_a?(Hash)

        files.values.select { |m| m.is_a?(Hash) && !m['hidden'] }.map do |m|
          [name.to_s, m['Version'].to_s, prerequisites(m['parentAA'])]
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

    # The cut-down list as the modules kept, with one object for each
    # distinct name, cluster id and set of prerequisites, since the same
    # ones repeat across thousands of versions.
    def modules(list, cluster_id)
      return nil unless list.is_a?(Array)

      shared = Hash.new { |table, value| table[value] = value.freeze }
      list.filter_map do |name, version, parents|
        next unless name.is_a?(String) && version.is_a?(String) && parents.is_a?(Array)

        sets = shared[parents.map { |set| shared[set.map { |item| shared[item.to_s] }] }]
        kept = Version.new(cluster_id: shared[cluster_id], version: version, prerequisites: sets)
        { name: shared[name], version: kept }
      end
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
