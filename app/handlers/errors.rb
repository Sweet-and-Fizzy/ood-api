# frozen_string_literal: true

module Handlers
  class NotFoundError < StandardError; end
  class ValidationError < StandardError; end
  class ForbiddenError < StandardError; end
  class AdapterError < StandardError; end
  class NotSupportedError < StandardError; end
  class PayloadTooLargeError < StandardError; end
  class StorageError < StandardError; end

  # Wraps every call into an ood_core job adapter.
  #
  # Adapters raise from three unrelated exception hierarchies, and only the
  # first is an OodCore::JobAdapterError:
  #
  #   * OodCore::JobAdapterError      — the documented adapter error
  #   * per-adapter classes           — e.g. Slurm::Batch::Error, which derives
  #                                     straight from StandardError and is NOT
  #                                     an OodCore::JobAdapterError
  #   * NotImplementedError/LoadError — ScriptError descendants, so a bare
  #                                     `rescue` does not catch them at all
  #
  # Rescuing only the first lets the other two escape as unexplained 500s.
  # Errors this app raises deliberately; they carry their own HTTP status and
  # must pass through untouched rather than being flattened into AdapterError.
  PASSTHROUGH_ERRORS = [
    NotFoundError, ValidationError, ForbiddenError,
    NotSupportedError, PayloadTooLargeError, StorageError
  ].freeze

  def self.with_adapter(cluster, operation)
    yield
  rescue *PASSTHROUGH_ERRORS
    raise
  rescue NotImplementedError => e
    raise NotSupportedError, "#{operation} is not supported by the '#{cluster.id}' adapter: #{e.message}"
  rescue LoadError => e
    raise AdapterError, "Cluster '#{cluster.id}' has an unsupported or misconfigured job adapter: #{e.message}"
  rescue StandardError => e
    raise AdapterError, "Failed to #{operation}: #{e.message}"
  end
end
