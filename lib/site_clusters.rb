# frozen_string_literal: true

require 'ood_core'

module OodApi
  # The site's clusters, as the web app and the MCP tools both see them,
  # whichever of them is running: the stdio helper loads the tools without
  # the web app.
  module SiteClusters
    PATH = ENV.fetch('OOD_CLUSTERS', '/etc/ood/config/clusters.d')

    class << self
      # Read again when the files change, so a cluster the site hides or
      # removes stops being offered without a PUN restart.
      #
      # @return [OodCore::Clusters]
      def all
        current = stamp
        @all = nil unless current == @stamp
        @stamp = current
        @all ||= OodCore::Clusters.load_file(PATH)
      end

      private

      # Looked at no more than once a second.
      def stamp
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return @stamp if @checked && now - @checked < 1

        @checked = now
        Dir.glob(File.join(PATH, '*')).map do |file|
          stat = File.stat(file)
          [file, stat.mtime.to_f, stat.ctime.to_f, stat.size]
        rescue SystemCallError
          [file]
        end
      end
    end
  end
end
