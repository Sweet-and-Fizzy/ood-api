# frozen_string_literal: true

require 'sinatra/base'
# Rack autoloads this; require it explicitly so QueryParser::QueryLimitError is
# defined by the time the error handler below references it.
require 'rack/query_parser'
require 'json'
require 'etc'
require 'fileutils'
require 'ood_core'
require_relative '../lib/api_token'
require_relative '../lib/app_auth'
require_relative 'handlers/audit'
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

    # No CORS headers are set here on purpose. This app is served under the
    # OOD proxy at /pun/sys/ood-api, so its browser clients are same-origin
    # (see docs/api.md) and its programmatic clients (curl, MCP) send a
    # bearer token server-to-server without a CORS preflight. The only
    # genuinely cross-origin surface — the /.well-known/oauth-* discovery
    # documents — is served by Apache, which sets its own
    # Access-Control-Allow-Origin (see docs/mcp-auth.md). A wildcard here
    # would grant any website scripted access to a logged-in user's session
    # without protecting anything. If a site ever fronts this API with a
    # cross-origin SPA, add an explicit, origin-scoped allow-list then.

    # Authentication runs first so an unauthenticated caller learns nothing —
    # not even the configured size limits. `authenticate!` reads only
    # request.env, never `params`, so it does not trigger the body parse the
    # next filter exists to prevent.
    before '/api/v1/*' do
      authenticate!
    end

    # CSRF defense for state-changing requests.
    #
    # With OOD's default `AuthType openid-connect`, Apache authenticates via
    # the `mod_auth_openidc_session` cookie — which a browser attaches to a
    # cross-origin form post automatically. An attacker page could therefore
    # POST or PUT here as a logged-in user. The absence of CORS headers stops
    # them reading the response, but not the write landing.
    #
    # An HTML form can only send `application/x-www-form-urlencoded`,
    # `multipart/form-data`, or `text/plain`; anything else triggers a
    # preflight, which our missing CORS headers then fail. Requiring JSON is
    # therefore a complete defense against form-based CSRF and costs a
    # legitimate client nothing — every documented example already sends it.
    #
    # `X-OOD-API-Token` is likewise unforgeable cross-origin, so sites with
    # app tokens enabled were already covered; this extends that to the
    # default configuration.
    before '/api/v1/*' do
      next unless ['POST', 'PUT', 'PATCH', 'DELETE'].include?(request.request_method)
      # DELETE and a bodyless POST carry no body to mislabel, but still must
      # not be drivable from a form — a custom header is what a form cannot
      # set, so accept either that or a JSON content type.
      next if OodApi::AppAuth.extract_token(request.env)

      next if request.media_type.to_s.downcase == 'application/json'
      # A bodyless request carries nothing a form could have supplied, and
      # DELETE is the normal case: clients send no body and no Content-Type,
      # and both curl and Rack fill in a default one regardless.
      next if request.content_length.to_i.zero?

      halt_error(415, 'unsupported_media_type',
                 'State-changing requests require Content-Type: application/json')
    end

    # Reject oversized bodies before anything touches `params`.
    #
    # Sinatra resolves `params` lazily, and Rack parses the body when it does.
    # A client that omits Content-Type gets the form-encoded default, so Rack
    # tries to parse a multi-megabyte upload as a form and raises
    # Rack::QueryParser::QueryLimitError from inside `params` — before any
    # route code runs, and well below our own write limit. Checking
    # content_length uses only headers, so it never triggers a parse.
    before '/api/v1/*' do
      max_write = Handlers::Files::MAX_FILE_WRITE
      next if request.content_length.to_i <= max_write

      # Generic wording: this filter guards every endpoint, and most of them
      # (job submission, for one) involve no file at all.
      halt_error(413, 'payload_too_large', "Request body too large (max #{max_write} bytes)")
    end

    # Belt and braces: if a body still reaches Rack's parser and blows its
    # query limit, report it as 413 rather than an unexplained 500.
    error Rack::QueryParser::QueryLimitError do
      halt_error(413, 'payload_too_large', 'Request body too large to parse')
    end

    # An operation the site's scheduler adapter does not implement — e.g.
    # `accounts` on an adapter with no accounting support. Distinct from
    # AdapterError (503), which means the adapter is present but failed.
    error Handlers::NotSupportedError do
      halt_error(501, 'not_implemented', env['sinatra.error'].message)
    end

    # Default status for every handler error, so a route that omits a rescue
    # degrades to the right code instead of an unexplained 500. Routes keep
    # their own rescues where they need a different status than the default
    # (PayloadTooLargeError is 400 on a read, since there the client asked for
    # too much rather than sent too much), and a route-level rescue always
    # wins over these.
    #
    # The rescue lists had drifted apart per route: PUT /files 500'd on
    # NotFoundError, POST /files on StorageError, GET /files on
    # ValidationError. Enumerating them centrally is what keeps that from
    # silently recurring as routes are added.
    {
      Handlers::NotFoundError             => [404, 'not_found'],
      Handlers::ValidationError           => [400, 'bad_request'],
      Handlers::ForbiddenError            => [403, 'forbidden'],
      Handlers::PayloadTooLargeError      => [413, 'payload_too_large'],
      Handlers::StorageError              => [507, 'insufficient_storage'],
      Handlers::AdapterError              => [503, 'service_unavailable'],
      # Same status as its parent, listed so the mapping survives any future
      # change to AdapterError's default.
      Handlers::SchedulerUnavailableError => [503, 'service_unavailable']
    }.each do |klass, (code, type)|
      error klass do
        halt_error(code, type, env['sinatra.error'].message)
      end
    end

    # Safety net. LoadError and NotImplementedError descend from ScriptError,
    # not StandardError, so neither a bare `rescue` nor Sinatra's default
    # handling catches them; without this they surface as an empty 500.
    error ScriptError do
      halt_error(500, 'internal_error', "Adapter error: #{env['sinatra.error'].message}")
    end

    # Health check (no auth required)
    get '/health' do
      { status: 'ok' }.to_json
    end

    # ============ Clusters ============

    get '/api/v1/clusters' do
      clusters = Handlers::Audit.log(op: 'list_clusters', user: current_user, source: 'rest') do
        Handlers::Clusters.list(clusters: self.class.clusters)
      end
      { data: clusters.map { |c| cluster_json(c) } }.to_json
    end

    get '/api/v1/clusters/:id' do
      cluster = Handlers::Audit.log(op: 'get_cluster', user: current_user, source: 'rest', cluster: params[:id]) do
        Handlers::Clusters.get(clusters: self.class.clusters, id: params[:id])
      end
      { data: cluster_json(cluster) }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    end

    # ============ Accounts ============

    get '/api/v1/accounts' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?

      accounts = Handlers::Audit.log(op: 'list_accounts', user: current_user, source: 'rest',
                                     cluster: params[:cluster]) do
        Handlers::Clusters.accounts(clusters: self.class.clusters, id: params[:cluster])
      end
      { data: accounts.map(&:to_h) }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::AdapterError => e
      halt_service_unavailable(e.message)
    end

    # ============ Queues ============

    get '/api/v1/queues' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?

      queues = Handlers::Audit.log(op: 'list_queues', user: current_user, source: 'rest', cluster: params[:cluster]) do
        Handlers::Clusters.queues(clusters: self.class.clusters, id: params[:cluster])
      end
      { data: queues.map(&:to_h) }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::AdapterError => e
      halt_service_unavailable(e.message)
    end

    # ============ Cluster Info ============

    get '/api/v1/cluster_info' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?

      info = Handlers::Audit.log(op: 'cluster_info', user: current_user, source: 'rest', cluster: params[:cluster]) do
        Handlers::Clusters.info(clusters: self.class.clusters, id: params[:cluster])
      end
      { data: info.to_h }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::AdapterError => e
      halt_service_unavailable(e.message)
    end

    # ============ Jobs ============

    get '/api/v1/jobs' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?

      jobs, cluster = Handlers::Audit.log(op: 'list_jobs', user: current_user, source: 'rest',
                                          cluster: params[:cluster]) do
        Handlers::Jobs.list(
          clusters:   self.class.clusters,
          cluster_id: params[:cluster],
          user:       current_user
        )
      end
      { data: jobs.map { |j| job_json(j, cluster) } }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::AdapterError => e
      halt_service_unavailable(e.message)
    end

    get '/api/v1/jobs/historic' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?

      jobs, cluster = Handlers::Audit.log(op: 'list_historic_jobs', user: current_user, source: 'rest',
                                          cluster: params[:cluster]) do
        Handlers::Jobs.historic(
          clusters:   self.class.clusters,
          cluster_id: params[:cluster],
          user:       current_user
        )
      end
      { data: jobs.map { |j| job_json(j, cluster) } }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::AdapterError => e
      halt_service_unavailable(e.message)
    end

    get '/api/v1/jobs/:id' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?

      job, cluster = Handlers::Audit.log(op: 'get_job', user: current_user, source: 'rest', cluster: params[:cluster],
                                         job_id: params[:id]) do
        Handlers::Jobs.get(
          clusters:   self.class.clusters,
          cluster_id: params[:cluster],
          job_id:     params[:id]
        )
      end
      { data: job_json(job, cluster) }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    end

    post '/api/v1/jobs' do
      body = parse_json_object(request.body.read)
      halt_bad_request('Missing cluster in request body') if body['cluster'].to_s.strip.empty?
      # `script` and `options` are indexed with dig below, which raises TypeError
      # on a String and NoMethodError on a scalar. Valid JSON of the wrong shape
      # is a client error, not a 500.
      halt_bad_request('script must be an object') unless body['script'].nil? || body['script'].is_a?(Hash)
      halt_bad_request('options must be an object') unless body['options'].nil? || body['options'].is_a?(Hash)

      job_info, cluster = Handlers::Audit.log(op: 'submit_job', user: current_user, source: 'rest',
                                              cluster: body['cluster']) do
        Handlers::Jobs.submit(
          clusters:       self.class.clusters,
          cluster_id:     body['cluster'],
          script_content: body.dig('script', 'content'),
          workdir:        body.dig('script', 'workdir'),
          job_name:       body.dig('options', 'job_name'),
          queue_name:     body.dig('options', 'queue_name'),
          accounting_id:  body.dig('options', 'accounting_id'),
          wall_time:      body.dig('options', 'wall_time'),
          output_path:    body.dig('options', 'output_path'),
          error_path:     body.dig('options', 'error_path'),
          native:         body.dig('options', 'native'),
          after:          body.dig('options', 'after'),
          afterok:        body.dig('options', 'afterok'),
          afternotok:     body.dig('options', 'afternotok'),
          afterany:       body.dig('options', 'afterany')
        )
      end
      status 201
      { data: job_json(job_info, cluster) }.to_json
    rescue JSON::ParserError
      halt_bad_request('Invalid JSON in request body')
    rescue Handlers::ValidationError => e
      halt_bad_request(e.message)
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::SchedulerUnavailableError => e
      halt_service_unavailable(e.message)
    rescue Handlers::AdapterError => e
      halt_unprocessable(e.message)
    end

    delete '/api/v1/jobs/:id' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?

      result = Handlers::Audit.log(op: 'cancel_job', user: current_user, source: 'rest', cluster: params[:cluster],
                                   job_id: params[:id]) do
        Handlers::Jobs.cancel(
          clusters:   self.class.clusters,
          cluster_id: params[:cluster],
          job_id:     params[:id]
        )
      end
      { data: result }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::SchedulerUnavailableError => e
      halt_service_unavailable(e.message)
    rescue Handlers::AdapterError => e
      halt_unprocessable(e.message)
    end

    post '/api/v1/jobs/:id/hold' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?

      result = Handlers::Audit.log(op: 'hold_job', user: current_user, source: 'rest', cluster: params[:cluster],
                                   job_id: params[:id]) do
        Handlers::Jobs.hold(clusters: self.class.clusters, cluster_id: params[:cluster], job_id: params[:id])
      end
      { data: result }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::SchedulerUnavailableError => e
      halt_service_unavailable(e.message)
    rescue Handlers::AdapterError => e
      halt_unprocessable(e.message)
    end

    post '/api/v1/jobs/:id/release' do
      halt_bad_request('Missing cluster parameter') unless params[:cluster] && !params[:cluster].empty?

      result = Handlers::Audit.log(op: 'release_job', user: current_user, source: 'rest', cluster: params[:cluster],
                                   job_id: params[:id]) do
        Handlers::Jobs.release(clusters: self.class.clusters, cluster_id: params[:cluster], job_id: params[:id])
      end
      { data: result }.to_json
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    rescue Handlers::SchedulerUnavailableError => e
      halt_service_unavailable(e.message)
    rescue Handlers::AdapterError => e
      halt_unprocessable(e.message)
    end

    # ============ Files ============

    # List directory contents or get file metadata
    get '/api/v1/files' do
      path = path_param!

      result = Handlers::Audit.log(op: 'list_files', user: current_user, source: 'rest', path: path) do
        Handlers::Files.list(path: path)
      end

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
      path = path_param!

      # Validate before to_i: "abc".to_i is 0 (silently returning an empty
      # body) and a negative reaches File.read, which raises ArgumentError.
      max_size = parse_max_size(params[:max_size])

      content_type 'application/octet-stream'
      Handlers::Audit.log(op: 'read_file', user: current_user, source: 'rest', path: path) do
        Handlers::Files.read(path: path, max_size: max_size)
      end
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
      path = path_param!

      if params[:type] == 'directory'
        result = Handlers::Audit.log(op: 'create_directory', user: current_user, source: 'rest', path: path) do
          Handlers::Files.mkdir(path: path)
        end
      else
        halt_bad_request('Use PUT to write file contents') unless params[:touch]
        result = Handlers::Audit.log(op: 'touch_file', user: current_user, source: 'rest', path: path) do
          Handlers::Files.touch(path: path)
        end
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
      path = path_param!

      # Limit request body size to prevent memory exhaustion
      max_write = Handlers::Files::MAX_FILE_WRITE
      content_length = request.content_length.to_i
      halt_error(413, 'payload_too_large', "File too large (max #{max_write} bytes)") if content_length > max_write

      content = request.body.read(max_write + 1) || ''
      halt_error(413, 'payload_too_large', "File too large (max #{max_write} bytes)") if content.bytesize > max_write

      append = params[:append] == 'true'
      result = Handlers::Audit.log(op: 'write_file', user: current_user, source: 'rest', path: path) do
        Handlers::Files.write(path: path, content: content, append: append)
      end
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
      path = path_param!

      result = Handlers::Audit.log(op: 'delete_file', user: current_user, source: 'rest', path: path) do
        Handlers::Files.delete(path: path, recursive: params[:recursive] == 'true')
      end
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
      prefix = scalar_param!(:prefix)
      vars = Handlers::Audit.log(op: 'list_env', user: current_user, source: 'rest') do
        Handlers::Env.list(prefix: prefix)
      end
      { data: vars }.to_json
    end

    get '/api/v1/env/:name' do
      result = Handlers::Audit.log(op: 'get_env', user: current_user, source: 'rest') do
        Handlers::Env.get(name: params[:name])
      end
      { data: result }.to_json
    rescue Handlers::ForbiddenError => e
      halt_forbidden(e.message)
    rescue Handlers::NotFoundError => e
      halt_not_found(e.message)
    end

    # ============ Context ============

    get '/api/v1/context' do
      content = Handlers::Audit.log(op: 'read_context', user: current_user, source: 'rest') do
        Handlers::Context.read
      end
      { data: { content: content } }.to_json
    end

    # ============ Helpers ============

    private

    # See OodApi::AppAuth. The same rule guards the MCP transport, so both
    # surfaces enforce app tokens identically.
    def authenticate!
      result = OodApi::AppAuth.authenticate(request.env)
      halt_unauthorized if result == false

      @current_token = result
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
      # `status` is the portable ood_core vocabulary, so a client can branch on
      # it across schedulers. It previously carried the raw native state, which
      # meant a queued Slurm job reported `pending` where the docs promised
      # `queued` — and the polling example in docs/api.md could never match.
      #
      # The native string is still exposed, as `native_state`, because it
      # distinguishes outcomes ood_core flattens: `cancelled`, `timeout`, and
      # `failed` all map to `completed`.
      native = info.native
      native_state = native&.dig(:state)
      native_state = native_state.to_s.downcase if native_state

      {
        job_id:          info.id,
        cluster:         cluster.id.to_s,
        job_name:        info.job_name,
        job_owner:       info.job_owner,
        status:          info.status.to_s,
        native_state:    native_state,
        queue_name:      info.queue_name,
        accounting_id:   info.accounting_id,
        submitted_at:    info.submission_time&.iso8601,
        started_at:      info.dispatch_time&.iso8601,
        wallclock_time:  info.wallclock_time,
        wallclock_limit: info.wallclock_limit
      }
    end

    # Returns nil when absent (meaning "no caller-supplied limit"), otherwise a
    # positive Integer. Halts 400 on anything else.
    def parse_max_size(raw)
      return nil if raw.nil? || raw.to_s.empty?

      halt_bad_request('max_size must be a positive integer') unless /\A\d+\z/.match?(raw.to_s)

      value = raw.to_i
      halt_bad_request('max_size must be greater than zero') if value.zero?

      value
    end

    def halt_error(status_code, error_type, message)
      halt status_code, { error: error_type, message: message }.to_json
    end

    # JSON.parse happily returns an Array, String, Integer or nil for a
    # well-formed document. Every caller here then indexes the result like a
    # Hash, so `[1,2,3]` or `null` became a TypeError/NoMethodError 500 rather
    # than a 400.
    def parse_json_object(raw)
      parsed = JSON.parse(raw)
      halt_bad_request('Request body must be a JSON object') unless parsed.is_a?(Hash)
      parsed
    end

    # Rack turns `?p[]=x` into an Array and `?p[k]=x` into a Hash, so a param
    # the handlers treat as a String arrives as neither and raises a TypeError
    # deep inside them. Returns nil when absent.
    def scalar_param!(name)
      value = params[name]
      return nil if value.nil?

      halt_bad_request("#{name} must be a single value") unless value.is_a?(String)

      value
    end

    # Required path param: present, a plain string, and free of null bytes —
    # a NUL reaches File.expand_path and raises ArgumentError, which is a
    # malformed request rather than a server fault.
    def path_param!
      value = scalar_param!(:path)
      halt_bad_request('Missing path parameter') if value.nil? || value.empty?
      halt_bad_request('path contains a null byte') if value.include?("\0")

      value
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
