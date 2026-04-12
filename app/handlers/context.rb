# frozen_string_literal: true

require 'pathname'
require_relative 'errors'

module Handlers
  module Context
    CONTEXT_PATH = ENV.fetch('OOD_API_CONTEXT_PATH', '/etc/ood/config/agents.d')

    def self.read
      dir = Pathname.new(CONTEXT_PATH)
      return '' unless dir.directory?

      files = dir.glob('*.md').sort
      return '' if files.empty?

      files.map do |f|
        "<!-- Source: #{f.basename} -->\n#{f.read.strip}"
      end.join("\n\n")
    end
  end
end
