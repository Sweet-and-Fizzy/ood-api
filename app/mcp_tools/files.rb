# frozen_string_literal: true

require 'mcp'
require_relative '../handlers/audit'
require_relative '../handlers/files'

class ListFilesTool < MCP::Tool
  tool_name 'list_files'
  description 'List contents of a directory or get file metadata'
  input_schema({
    type: 'object',
    properties: {
      path: { type: 'string', description: 'Absolute path to list' }
    },
    required: ['path']
  })

  def self.call(server_context:, path:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    result = Handlers::Audit.log(op: 'list_files', user: user, source: 'mcp', path: path) do
      Handlers::Files.list(path: path)
    end
    if result.is_a?(Array)
      lines = result.map do |p|
        type = p.directory? ? 'dir ' : 'file'
        "  #{type}  #{p.basename}"
      end
      text = "Directory: #{path}\n#{lines.join("\n")}"
    else
      text = "File: #{result.basename}\nPath: #{result}"
    end
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::ValidationError,
         Handlers::ForbiddenError, Handlers::PayloadTooLargeError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class ReadFileTool < MCP::Tool
  tool_name 'read_file'
  description 'Read the contents of a file'
  input_schema({
    type: 'object',
    properties: {
      path: { type: 'string', description: 'Absolute path to the file' }
    },
    required: ['path']
  })

  def self.call(server_context:, path:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    content = Handlers::Audit.log(op: 'read_file', user: user, source: 'mcp', path: path) do
      Handlers::Files.read(path: path)
    end
    MCP::Tool::Response.new([{ type: 'text', text: content }])
  rescue Handlers::NotFoundError, Handlers::ValidationError,
         Handlers::ForbiddenError, Handlers::PayloadTooLargeError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class WriteFileTool < MCP::Tool
  tool_name 'write_file'
  description 'Write content to a file (creates or overwrites)'
  input_schema({
    type: 'object',
    properties: {
      path: { type: 'string', description: 'Absolute path to write to' },
      content: { type: 'string', description: 'Content to write' }
    },
    required: %w[path content]
  })

  def self.call(server_context:, path:, content:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    result = Handlers::Audit.log(op: 'write_file', user: user, source: 'mcp', path: path) do
      Handlers::Files.write(path: path, content: content)
    end
    text = "File written: #{result}"
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::ValidationError,
         Handlers::ForbiddenError, Handlers::StorageError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class CreateDirectoryTool < MCP::Tool
  tool_name 'create_directory'
  description 'Create a new directory'
  input_schema({
    type: 'object',
    properties: {
      path: { type: 'string', description: 'Absolute path for the new directory' }
    },
    required: ['path']
  })

  def self.call(server_context:, path:, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    result = Handlers::Audit.log(op: 'create_directory', user: user, source: 'mcp', path: path) do
      Handlers::Files.mkdir(path: path)
    end
    text = "Directory created: #{result}"
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::ValidationError,
         Handlers::ForbiddenError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end

class DeleteFileTool < MCP::Tool
  tool_name 'delete_file'
  description 'Delete a file or directory'
  input_schema({
    type: 'object',
    properties: {
      path: { type: 'string', description: 'Absolute path to delete' },
      recursive: { type: 'boolean', description: 'Recursively delete directory contents (default: false)' }
    },
    required: ['path']
  })

  def self.call(server_context:, path:, recursive: false, **_params)
    user = ENV['USER'] || ENV['LOGNAME'] || 'unknown'
    result = Handlers::Audit.log(op: 'delete_file', user: user, source: 'mcp', path: path) do
      Handlers::Files.delete(path: path, recursive: recursive)
    end
    text = "Deleted: #{result[:path]}"
    MCP::Tool::Response.new([{ type: 'text', text: text }])
  rescue Handlers::NotFoundError, Handlers::ValidationError,
         Handlers::ForbiddenError => e
    MCP::Tool::Response.new([{ type: 'text', text: e.message }], error: true)
  end
end
