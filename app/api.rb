# frozen_string_literal: true

require 'sinatra/base'
require 'json'
require 'etc'
require 'ood_core'
require_relative '../lib/api_token'

module OodApi
  class App < Sinatra::Base
    # Load clusters from OOD_CLUSTERS environment variable or default location
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
      headers['Access-Control-Allow-Methods'] = 'GET, POST, DELETE, OPTIONS'
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

    # ============ Helpers ============

    private

    def authenticate!
      auth_header = request.env['HTTP_AUTHORIZATION']
      halt_unauthorized unless auth_header&.start_with?('Bearer ')

      token_value = auth_header.sub('Bearer ', '')
      @current_token = OodApi::ApiToken.find_by_token(token_value)
      halt_unauthorized unless @current_token

      # Update last used timestamp (async would be better but keep it simple)
      OodApi::ApiToken.touch(@current_token)
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
  end
end
