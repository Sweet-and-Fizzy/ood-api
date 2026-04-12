# frozen_string_literal: true

module Handlers
  class NotFoundError < StandardError; end
  class ValidationError < StandardError; end
  class ForbiddenError < StandardError; end
  class AdapterError < StandardError; end
  class PayloadTooLargeError < StandardError; end
  class StorageError < StandardError; end
end
