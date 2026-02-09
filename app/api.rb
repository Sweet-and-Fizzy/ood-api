# frozen_string_literal: true

require 'sinatra/base'
require 'json'
require 'etc'
require 'fileutils'
require 'ood_core'
require_relative '../lib/api_token'

module OodApi
  class App < Sinatra::Base
    # Configuration via environment variables
    CLUSTERS_PATH = ENV.fetch('OOD_CLUSTERS', '/etc/ood/config/clusters.d')
    MAX_FILE_READ = ENV.fetch('OOD_API_MAX_FILE_READ', 10 * 1024 * 1024).to_i   # Default 10 MB
    MAX_FILE_WRITE = ENV.fetch('OOD_API_MAX_FILE_WRITE', 50 * 1024 * 1024).to_i # Default 50 MB

    def self.clusters
      @clusters ||= OodCore::Clusters.load_file(CLUSTERS_PATH)
    end

    # JSON content type for all responses
    before do
      content_type :json
    end

    # CORS headers for API access
    before do
      headers['Access-Control-Allow-Origin'] = '*'
      headers['Access-Control-Allow-Methods'] = 'GET, POST, PUT, DELETE, OPTIONS'
      headers['Access-Control-Allow-Headers'] = 'Authorization, Content-Type'
    end

    options '*' do
      200
    end

    # Authentication
    before '/api/v1/*' do
      authenticate!
    end

    # Health check (no auth required)
    get '/health' do
      { status: 'ok' }.to_json
    end

    # ============ Clusters ============

    get '/api/v1/clusters' do
      clusters = self.class.clusters
                     .select(&:job_allow?)
                     .map { |c| cluster_json(c) }

      { data: clusters }.to_json
    end

    get '/api/v1/clusters/:id' do
      cluster = find_cluster(params[:id])
      halt_not_found('Cluster not found') unless cluster

      { data: cluster_json(cluster) }.to_json
    end

    # ============ Jobs ============

    get '/api/v1/jobs' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?
      cluster = find_cluster(params[:cluster])
      halt_not_found('Cluster not found') unless cluster

      adapter = cluster.job_adapter
      # Filter jobs by current user (from PUN environment)
      jobs = adapter.info_where_owner(current_user).map { |j| job_json(j, cluster) }

      { data: jobs }.to_json
    rescue OodCore::JobAdapterError => e
      halt_service_unavailable("Scheduler error: #{e.message}")
    end

    get '/api/v1/jobs/:id' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?
      cluster = find_cluster(params[:cluster])
      halt_not_found('Cluster not found') unless cluster

      adapter = cluster.job_adapter
      job = adapter.info(params[:id])

      # Check if job was found (all nil attrs means not found)
      halt_not_found('Job not found') if job.id.nil? || (job.job_name.nil? && job.job_owner.nil? && job.queue_name.nil?)

      { data: job_json(job, cluster) }.to_json
    rescue OodCore::JobAdapterError
      halt_not_found('Job not found')
    end

    post '/api/v1/jobs' do
      body = JSON.parse(request.body.read)

      cluster_id = body['cluster']
      halt_bad_request('Missing cluster in request body') if cluster_id.to_s.strip.empty?

      cluster = find_cluster(cluster_id)
      halt_not_found('Cluster not found') unless cluster

      script_data = body['script'] || {}
      options_data = body['options'] || {}

      script_content = script_data['content']
      halt_bad_request('script.content must be a string') unless script_content.is_a?(String)
      halt_bad_request('script.content cannot be empty') if script_content.strip.empty?

      # Build OodCore::Job::Script
      # Default workdir to /tmp if not specified
      workdir = script_data['workdir'] || '/tmp'
      script = OodCore::Job::Script.new(
        content:       script_content,
        workdir:       Pathname.new(workdir),
        job_name:      options_data['job_name'],
        queue_name:    options_data['queue_name'],
        accounting_id: options_data['accounting_id'],
        wall_time:     options_data['wall_time'],
        output_path:   options_data['output_path'] ? Pathname.new(options_data['output_path']) : nil,
        error_path:    options_data['error_path'] ? Pathname.new(options_data['error_path']) : nil,
        native:        options_data['native']
      )

      adapter = cluster.job_adapter
      job_id = adapter.submit(script)

      # Fetch the submitted job info
      job_info = adapter.info(job_id)

      status 201
      { data: job_json(job_info, cluster) }.to_json
    rescue JSON::ParserError
      halt_bad_request('Invalid JSON in request body')
    rescue OodCore::JobAdapterError => e
      halt_unprocessable("Job submission failed: #{e.message}")
    end

    delete '/api/v1/jobs/:id' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?
      cluster = find_cluster(params[:cluster])
      halt_not_found('Cluster not found') unless cluster

      adapter = cluster.job_adapter
      adapter.delete(params[:id])

      { data: { job_id: params[:id], status: 'cancelled' } }.to_json
    rescue OodCore::JobAdapterError => e
      halt_unprocessable("Failed to cancel job: #{e.message}")
    end

    # ============ Files ============

    # List directory contents or get file metadata
    get '/api/v1/files' do
      halt_bad_request('Missing path parameter') unless params[:path] && !params[:path].empty?

      path = normalize_path(params[:path])
      validate_path!(path)
      halt_not_found('Path not found') unless path.exist?

      if path.directory?
        # Sort: directories first, then by name (case-insensitive)
        children = path.children.select(&:readable?).sort_by { |p| [p.directory? ? 0 : 1, p.basename.to_s.downcase] }
        files = children.map { |p| file_json(p) }
        { data: files }.to_json
      else
        { data: file_json(path) }.to_json
      end
    rescue Errno::ENOENT
      halt_not_found('Path not found')
    rescue Errno::EACCES
      halt_forbidden('Permission denied')
    end

    # Read file contents
    get '/api/v1/files/content' do
      halt_bad_request('Missing path parameter') unless params[:path] && !params[:path].empty?

      path = normalize_path(params[:path])
      validate_path!(path)
      halt_not_found('File not found') unless path.exist?
      halt_bad_request('Cannot read directory contents') if path.directory?
      halt_forbidden('Permission denied') unless path.readable?

      # Limit file size to prevent memory issues
      halt_bad_request("File too large (max #{MAX_FILE_READ} bytes)") if path.size > MAX_FILE_READ

      content_type 'application/octet-stream'
      path.read
    rescue Errno::ENOENT
      halt_not_found('File not found')
    rescue Errno::EACCES
      halt_forbidden('Permission denied')
    end

    # Create file or directory
    post '/api/v1/files' do
      halt_bad_request('Missing path parameter') unless params[:path] && !params[:path].empty?

      path = normalize_path(params[:path])
      validate_path!(path)

      if params[:type] == 'directory'
        halt_bad_request('Path already exists') if path.exist?
        path.mkpath
      else
        halt_bad_request('Use PUT to write file contents') unless params[:touch]
        FileUtils.touch(path)
      end

      status 201
      { data: file_json(path) }.to_json
    rescue Errno::EACCES
      halt_forbidden('Permission denied')
    rescue Errno::EEXIST
      halt_bad_request('Path already exists')
    end

    # Write file contents
    put '/api/v1/files' do
      halt_bad_request('Missing path parameter') unless params[:path] && !params[:path].empty?

      path = normalize_path(params[:path])
      validate_path!(path)
      halt_bad_request('Cannot write to directory') if path.exist? && path.directory?

      # Limit request body size to prevent memory exhaustion
      content_length = request.content_length.to_i
      if content_length > MAX_FILE_WRITE
        halt_error(413, 'payload_too_large', "File too large (max #{MAX_FILE_WRITE} bytes)")
      end

      # Ensure parent directory exists
      path.parent.mkpath unless path.parent.exist?

      content = request.body.read(MAX_FILE_WRITE + 1) || ''
      if content.bytesize > MAX_FILE_WRITE
        halt_error(413, 'payload_too_large', "File too large (max #{MAX_FILE_WRITE} bytes)")
      end
      path.write(content)

      { data: file_json(path) }.to_json
    rescue Errno::EACCES
      halt_forbidden('Permission denied')
    rescue Errno::ENOSPC
      halt_error(507, 'insufficient_storage', 'No space left on device')
    end

    # Delete file or directory
    delete '/api/v1/files' do
      halt_bad_request('Missing path parameter') unless params[:path] && !params[:path].empty?

      path = normalize_path(params[:path])
      validate_path!(path)
      halt_not_found('Path not found') unless path.exist?

      if path.directory?
        if params[:recursive] == 'true'
          FileUtils.rm_rf(path)
        else
          halt_bad_request('Directory not empty') unless path.children.empty?
          path.rmdir
        end
      else
        path.delete
      end

      { data: { path: path.to_s, deleted: true } }.to_json
    rescue Errno::ENOENT
      halt_not_found('Path not found')
    rescue Errno::EACCES
      halt_forbidden('Permission denied')
    rescue Errno::ENOTEMPTY
      halt_bad_request('Directory not empty')
    end

    # ============ Helpers ============

    private

    def authenticate!
      # Option 1: Apache already validated JWT and set REMOTE_USER
      # In this case, we trust Apache's authentication
      if request.env['REMOTE_USER'] && !request.env['REMOTE_USER'].empty?
        @authenticated_via = :apache
        return
      end

      # Option 2: Application-level token authentication
      auth_header = request.env['HTTP_AUTHORIZATION']
      halt_unauthorized unless auth_header&.start_with?('Bearer ')

      token_value = auth_header.sub('Bearer ', '')
      @current_token = OodApi::ApiToken.find_by_token(token_value)
      halt_unauthorized unless @current_token

      # Update last used timestamp (async would be better but keep it simple)
      OodApi::ApiToken.touch(@current_token)
      @authenticated_via = :token
    end

    def current_user
      # In OOD's PUN architecture, the app runs as the authenticated user
      ENV['USER'] || ENV['LOGNAME'] || Etc.getlogin
    end

    def find_cluster(id)
      return nil unless id

      self.class.clusters.find { |c| c.id.to_s == id.to_s && c.job_allow? }
    end

    def cluster_json(cluster)
      {
        id:         cluster.id.to_s,
        title:      cluster.metadata.title || cluster.id.to_s,
        adapter:    cluster.job_config[:adapter],
        login_host: cluster.login&.host
      }
    end

    def job_json(info, cluster)
      # Use native scheduler state if available for accurate status
      native = info.native
      native_state = native&.dig(:state)
      native_state = native_state.to_s.downcase if native_state

      {
        job_id:          info.id,
        cluster:         cluster.id.to_s,
        job_name:        info.job_name,
        job_owner:       info.job_owner,
        status:          native_state || info.status.to_s,
        queue_name:      info.queue_name,
        accounting_id:   info.accounting_id,
        submitted_at:    info.submission_time&.iso8601,
        started_at:      info.dispatch_time&.iso8601,
        wallclock_time:  info.wallclock_time,
        wallclock_limit: info.wallclock_limit
      }
    end

    def halt_error(status_code, error_type, message)
      halt status_code, { error: error_type, message: message }.to_json
    end

    def halt_bad_request(message)
      halt_error(400, 'bad_request', message)
    end

    def halt_not_found(message)
      halt_error(404, 'not_found', message)
    end

    def halt_unauthorized
      halt_error(401, 'unauthorized', 'Invalid or missing API token')
    end

    def halt_unprocessable(message)
      halt_error(422, 'unprocessable_entity', message)
    end

    def halt_service_unavailable(message)
      halt_error(503, 'service_unavailable', message)
    end

    def halt_forbidden(message)
      halt_error(403, 'forbidden', message)
    end

    # ============ File Helpers ============

    def normalize_path(path_str)
      # Expand ~ to home directory, normalize path
      expanded = File.expand_path(path_str)
      Pathname.new(expanded)
    end

    def validate_path!(path)
      # Security: prevent path traversal and restrict to safe locations
      # By default, allow access to user's home directory and temp directories
      allowed_roots = allowed_path_roots

      # Check if path is under an allowed root
      real_path = path.exist? ? path.realpath : find_real_parent(path)
      allowed = allowed_roots.any? { |root| path_under?(real_path, root) }
      halt_forbidden('Access denied: path not in allowed directories') unless allowed
    end

    def allowed_path_roots
      roots = []

      # Home directory
      home = Pathname.new(Dir.home)
      roots << (home.exist? ? home.realpath : home)

      # System temp directories - resolve symlinks for cross-platform compatibility
      ['/tmp', Dir.tmpdir].each do |tmp|
        tmp_path = Pathname.new(tmp)
        roots << (tmp_path.exist? ? tmp_path.realpath : tmp_path)
      end

      roots.uniq
    end

    def path_under?(child, parent)
      child_str = child.to_s
      parent_str = parent.to_s
      return true if child_str == parent_str

      child_str.start_with?(parent_str) && child_str[parent_str.length] == '/'
    end

    def find_real_parent(path)
      # For non-existent paths, find the first existing parent's realpath
      path.ascend do |p|
        return p.realpath if p.exist?
      end
      Pathname.new('/')
    end

    def file_json(path)
      stat = path.stat
      build_file_hash(path, stat)
    rescue Errno::ENOENT
      { path: path.to_s, name: path.basename.to_s, error: 'not found' }
    rescue ArgumentError
      build_file_hash(path, stat, use_ids: true)
    end

    def build_file_hash(path, stat, use_ids: false)
      {
        path:      path.to_s,
        name:      path.basename.to_s,
        directory: path.directory?,
        size:      path.directory? ? nil : stat.size,
        mode:      stat.mode,
        owner:     use_ids ? stat.uid.to_s : Etc.getpwuid(stat.uid).name,
        group:     use_ids ? stat.gid.to_s : Etc.getgrgid(stat.gid).name,
        mtime:     stat.mtime.iso8601
      }
    end
  end
end
