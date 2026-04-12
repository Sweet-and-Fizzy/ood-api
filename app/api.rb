# frozen_string_literal: true

require 'sinatra/base'
require 'json'
require 'etc'
require 'fileutils'
require 'ood_core'
require_relative '../lib/api_token'
require_relative 'handlers/clusters'
require_relative 'handlers/jobs'
require_relative 'handlers/files'
require_relative 'handlers/env'
require_relative 'handlers/context'

module OodApi
  class App < Sinatra::Base
    # Configuration via environment variables
    CLUSTERS_PATH = ENV.fetch('OOD_CLUSTERS', '/etc/ood/config/clusters.d')

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
      clusters = Handlers::Clusters.list(clusters: self.class.clusters)
      { data: clusters.map { |c| cluster_json(c) } }.to_json
    end

    get '/api/v1/clusters/:id' do
      cluster = Handlers::Clusters.get(clusters: self.class.clusters, id: params[:id])
      { data: cluster_json(cluster) }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    end

    # ============ Jobs ============

    get '/api/v1/jobs' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?

      jobs, cluster = Handlers::Jobs.list(
        clusters: self.class.clusters,
        cluster_id: params[:cluster],
        user: current_user
      )
      { data: jobs.map { |j| job_json(j, cluster) } }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::AdapterError => e
      halt_service_unavailable(e.message)
    end

    get '/api/v1/jobs/:id' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?

      job, cluster = Handlers::Jobs.get(
        clusters: self.class.clusters,
        cluster_id: params[:cluster],
        job_id: params[:id]
      )
      { data: job_json(job, cluster) }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    end

    post '/api/v1/jobs' do
      body = JSON.parse(request.body.read)
      halt_bad_request('Missing cluster in request body') if body['cluster'].to_s.strip.empty?

      job_info, cluster = Handlers::Jobs.submit(
        clusters: self.class.clusters,
        cluster_id: body['cluster'],
        script_content: body.dig('script', 'content'),
        workdir: body.dig('script', 'workdir'),
        job_name: body.dig('options', 'job_name'),
        queue_name: body.dig('options', 'queue_name'),
        accounting_id: body.dig('options', 'accounting_id'),
        wall_time: body.dig('options', 'wall_time'),
        output_path: body.dig('options', 'output_path'),
        error_path: body.dig('options', 'error_path'),
        native: body.dig('options', 'native')
      )
      status 201
      { data: job_json(job_info, cluster) }.to_json
    rescue JSON::ParserError
      halt_bad_request('Invalid JSON in request body')
    rescue Handlers::ValidationError => e
      halt_bad_request(e.message)
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::AdapterError => e
      halt_unprocessable(e.message)
    end

    delete '/api/v1/jobs/:id' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?

      result = Handlers::Jobs.cancel(
        clusters: self.class.clusters,
        cluster_id: params[:cluster],
        job_id: params[:id]
      )
      { data: result }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::AdapterError => e
      halt_unprocessable(e.message)
    end

    # ============ Files ============

    # List directory contents or get file metadata
    get '/api/v1/files' do
      halt_bad_request('Missing path parameter') unless params[:path] && !params[:path].empty?

      result = Handlers::Files.list(path: params[:path])

      if result.is_a?(Array)
        { data: result.map { |p| file_json(p) } }.to_json
      else
        { data: file_json(result) }.to_json
      end
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::ForbiddenError => e
      halt_forbidden(e.message)
    end

    # Read file contents
    get '/api/v1/files/content' do
      halt_bad_request('Missing path parameter') unless params[:path] && !params[:path].empty?

      content_type 'application/octet-stream'
      Handlers::Files.read(path: params[:path])
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::ValidationError => e
      halt_bad_request(e.message)
    rescue Handlers::ForbiddenError => e
      halt_forbidden(e.message)
    rescue Handlers::PayloadTooLargeError => e
      halt_bad_request(e.message)
    end

    # Create file or directory
    post '/api/v1/files' do
      halt_bad_request('Missing path parameter') unless params[:path] && !params[:path].empty?

      if params[:type] == 'directory'
        result = Handlers::Files.mkdir(path: params[:path])
      else
        halt_bad_request('Use PUT to write file contents') unless params[:touch]
        result = Handlers::Files.touch(path: params[:path])
      end

      status 201
      { data: file_json(result) }.to_json
    rescue Handlers::ValidationError => e
      halt_bad_request(e.message)
    rescue Handlers::ForbiddenError => e
      halt_forbidden(e.message)
    end

    # Write file contents
    put '/api/v1/files' do
      halt_bad_request('Missing path parameter') unless params[:path] && !params[:path].empty?

      # Limit request body size to prevent memory exhaustion
      max_write = Handlers::Files::MAX_FILE_WRITE
      content_length = request.content_length.to_i
      if content_length > max_write
        halt_error(413, 'payload_too_large', "File too large (max #{max_write} bytes)")
      end

      content = request.body.read(max_write + 1) || ''
      if content.bytesize > max_write
        halt_error(413, 'payload_too_large', "File too large (max #{max_write} bytes)")
      end

      result = Handlers::Files.write(path: params[:path], content: content)
      { data: file_json(result) }.to_json
    rescue Handlers::ValidationError => e
      halt_bad_request(e.message)
    rescue Handlers::ForbiddenError => e
      halt_forbidden(e.message)
    rescue Handlers::StorageError
      halt_error(507, 'insufficient_storage', 'No space left on device')
    end

    # Delete file or directory
    delete '/api/v1/files' do
      halt_bad_request('Missing path parameter') unless params[:path] && !params[:path].empty?

      result = Handlers::Files.delete(path: params[:path], recursive: params[:recursive] == 'true')
      { data: result }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::ValidationError => e
      halt_bad_request(e.message)
    rescue Handlers::ForbiddenError => e
      halt_forbidden(e.message)
    end

    # ============ Environment Variables ============

    get '/api/v1/env' do
      vars = Handlers::Env.list(prefix: params[:prefix])
      { data: vars }.to_json
    end

    get '/api/v1/env/:name' do
      result = Handlers::Env.get(name: params[:name])
      { data: result }.to_json
    rescue Handlers::ForbiddenError => e
      halt_forbidden(e.message)
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    end

    # ============ Context ============

    get '/api/v1/context' do
      content = Handlers::Context.read
      { data: { content: content } }.to_json
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
