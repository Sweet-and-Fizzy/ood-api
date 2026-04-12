# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/mcp_tools/context'

class McpContextResourceTest < Minitest::Test
  def test_context_resource_has_correct_uri
    assert_equal 'ood://context', CONTEXT_RESOURCE.uri
  end

  def test_context_resource_has_correct_mime_type
    assert_equal 'text/markdown', CONTEXT_RESOURCE.mime_type
  end

  def test_context_resource_has_name_and_description
    refute_nil CONTEXT_RESOURCE.name
    refute_nil CONTEXT_RESOURCE.description
  end
end
