# frozen_string_literal: true

module Handlers
  class NotFoundError < StandardError; end
  class ValidationError < StandardError; end
  class ForbiddenError < StandardError; end
  # The adapter ran and the scheduler answered, but rejected the request — a
  # bad queue name, an account the user cannot charge, a resource request the
  # partition cannot satisfy. The caller can fix these by changing the request.
  class AdapterError < StandardError; end

  # The scheduler could not be reached at all. Nothing about the request is
  # wrong, so it is not the caller's to fix — retrying later may work.
  # Separate from AdapterError so routes can map it to 503 rather than 422.
  # It subclasses AdapterError, so a route rescuing both must list this first.
  class SchedulerUnavailableError < AdapterError; end
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

  # Recognising "the scheduler is down" from an adapter error message.
  #
  # This is a heuristic, and deliberately so: ood_core has no portable
  # unreachable-scheduler exception. Slurm raises SlurmTimeoutError for socket
  # timeouts but plain Batch::Error for "Unable to contact slurm controller",
  # and other adapters classify nothing at all. Matching the message is the
  # only signal available across adapters.
  #
  # A miss degrades safely: the error stays an AdapterError, which is what
  # every route did with it before. Nothing is hidden either way — the
  # scheduler's own text is always passed through to the caller.
  UNAVAILABLE_PATTERNS = [
    /unable to contact/i,
    /socket timed out/i,
    /connection (refused|timed out|reset)/i,
    /could not connect/i,
    /no route to host/i,
    /host is (down|unreachable)/i,
    /timed out/i
  ].freeze

  def self.unavailable?(message)
    # Scheduler stderr is arbitrary bytes, and Regexp#match? raises
    # ArgumentError on invalid UTF-8 — which would turn a clean 503 into a 500
    # from inside the error path itself. Scrub rather than skip: the bad bytes
    # are almost never in the part that says "connection refused".
    text = message.to_s
    text = text.scrub('?') unless text.valid_encoding?
    UNAVAILABLE_PATTERNS.any? { |p| p.match?(text) }
  end

  def self.with_adapter(cluster, operation)
    yield
  rescue *PASSTHROUGH_ERRORS
    raise
  rescue NotImplementedError => e
    raise NotSupportedError, "#{operation} is not supported by the '#{cluster.id}' adapter: #{e.message}"
  rescue LoadError => e
    raise AdapterError, "Cluster '#{cluster.id}' has an unsupported or misconfigured job adapter: #{e.message}"
  rescue StandardError => e
    raise SchedulerUnavailableError, "Failed to #{operation}: #{e.message}" if unavailable?(e.message)

    raise AdapterError, "Failed to #{operation}: #{e.message}"
  end
end
