# frozen_string_literal: true

require_relative 'base'
require_relative '../handlers/files'

module OodApi
  module Tools
    # Tool responses are serialised with to_json, which raises on a string that is
    # not valid in its own encoding — and the transport turns that into a bare HTTP
    # 500 with no JSON-RPC envelope, after the handler has already run.
    #
    # File contents are the common case. The PUN starts with no LANG, so
    # Encoding.default_external is US-ASCII and File.read tags the result US-ASCII;
    # a single accented character then makes the string invalid and read_file 500s
    # on a file it had just written. Real files are arbitrary bytes in any case, so
    # reinterpret as UTF-8 and replace whatever still does not decode.
    module McpText
      def self.safe_text(value)
        text = value.to_s
        text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
        text.valid_encoding? ? text : text.scrub('?')
      end
    end

    # MCP tool: list a directory or describe a file.
    class ListFilesTool < Base
      tool_name 'list_files'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'List contents of a directory or get file metadata'
      input_schema({
        type:       'object',
        properties: {
          path: { type: 'string', description: 'Absolute path to list' }
        },
        required:   ['path']
      })

      def self.run(path:, **_params)
        result = audited('list_files', path: path) do
          Handlers::Files.list(path: path)
        end
        if result.is_a?(Array)
          lines = result.map do |p|
            type = if p.directory? then 'dir '
                   else
                     p.symlink? ? 'link' : 'file'
                   end
            "  #{type}  #{p.basename}"
          end
          text = "Directory: #{path}\n#{lines.join("\n")}"
        else
          text = "File: #{result.basename}\nPath: #{result}"
        end
        text_response(text)
      rescue ArgumentError => e
        error_response("Invalid path: #{e.message}")
      end
    end

    # MCP tool: read a file's contents.
    class ReadFileTool < Base
      tool_name 'read_file'
      annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'Read the contents of a file'
      input_schema({
        type:       'object',
        properties: {
          path:     { type: 'string', description: 'Absolute path to the file' },
          max_size: { type: 'integer', description: 'Maximum bytes to read (default: server limit)' }
        },
        required:   ['path']
      })

      def self.run(path:, max_size: nil, **_params)
        content = audited('read_file', path: path) do
          Handlers::Files.read(path: path, max_size: max_size)
        end
        text_response(McpText.safe_text(content))
      rescue ArgumentError => e
        error_response("Invalid path: #{e.message}")
      end
    end

    # MCP tool: write or append to a file.
    class WriteFileTool < Base
      tool_name 'write_file'
      annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: false, open_world_hint: false)
      description 'Write content to a file (creates or overwrites)'
      input_schema({
        type:       'object',
        properties: {
          path:    { type: 'string', description: 'Absolute path to write to' },
          content: { type: 'string', description: 'Content to write' },
          append:  { type: 'boolean', description: 'Append to file instead of overwriting (default: false)' }
        },
        required:   ['path', 'content']
      })

      def self.run(path:, content:, append: false, **_params)
        result = audited('write_file', path: path) do
          Handlers::Files.write(path: path, content: content, append: append)
        end
        text = "File written: #{result}"
        text_response(text)
      rescue ArgumentError => e
        error_response("Invalid path: #{e.message}")
      end
    end

    # MCP tool: create a directory.
    class CreateDirectoryTool < Base
      tool_name 'create_directory'
      annotations(read_only_hint: false, destructive_hint: false, idempotent_hint: true, open_world_hint: false)
      description 'Create a new directory'
      input_schema({
        type:       'object',
        properties: {
          path: { type: 'string', description: 'Absolute path for the new directory' }
        },
        required:   ['path']
      })

      def self.run(path:, **_params)
        result = audited('create_directory', path: path) do
          Handlers::Files.mkdir(path: path)
        end
        text = "Directory created: #{result}"
        text_response(text)
      rescue ArgumentError => e
        error_response("Invalid path: #{e.message}")
      end
    end

    # MCP tool: delete a file or directory.
    class DeleteFileTool < Base
      tool_name 'delete_file'
      annotations(read_only_hint: false, destructive_hint: true, idempotent_hint: true, open_world_hint: false)
      description 'Delete a file or directory'
      input_schema({
        type:       'object',
        properties: {
          path:      { type: 'string', description: 'Absolute path to delete' },
          recursive: { type: 'boolean', description: 'Recursively delete directory contents (default: false)' }
        },
        required:   ['path']
      })

      def self.run(path:, recursive: false, **_params)
        result = audited('delete_file', path: path) do
          Handlers::Files.delete(path: path, recursive: recursive)
        end
        text = "Deleted: #{result[:path]}"
        text_response(text)
      rescue ArgumentError => e
        error_response("Invalid path: #{e.message}")
      end
    end
  end
end
