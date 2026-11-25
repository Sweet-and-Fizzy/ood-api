# frozen_string_literal: true

require 'ood_core'
require_relative '../app/handlers/errors'

module OodApi
  # The site's clusters, as the web app and the MCP tools both see them,
  # whichever of them is running: the stdio helper loads the tools without
  # the web app.
  module SiteClusters
    DEFAULT_PATH = '/etc/ood/config/clusters.d'

    class << self
      # Read again when the files change, so a cluster the site hides or
      # removes stops being offered without a PUN restart.
      #
      # @return [OodCore::Clusters]
      # @raise [Handlers::ConfigurationError] when the directory is missing
      def all
        current = stamp
        @all = nil unless current == @stamp
        @stamp = current
        @all ||= OodCore::Clusters.load_file(path)
      rescue OodCore::ConfigurationNotFound
        # Otherwise this reaches an MCP client as a bare protocol error and a
        # REST caller as an unexplained 500. Nothing is cached, so the
        # directory is read as soon as it appears.
        raise Handlers::ConfigurationError,
              "No cluster configuration was found at #{path}. The site's administrators need to fix this."
      end

      private

      # Read on every call so a test, or the stdio helper's environment, can
      # point it elsewhere.
      def path
        ENV.fetch('OOD_CLUSTERS', DEFAULT_PATH)
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Looked at no more than once a second.
      def stamp
        current = now
        return @stamp if @checked && current - @checked < 1

        @checked = current
        Dir.glob(File.join(path, '*')).map do |file|
          stat = File.stat(file)
          [file, stat.mtime.to_f, stat.ctime.to_f, stat.size]
        rescue SystemCallError
          [file]
        end
      end
    end
  end
end
