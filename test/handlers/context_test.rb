# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/context'

class HandlersContextTest < Minitest::Test
  def setup
    @test_dir = File.join(Dir.tmpdir, "ood-context-test-#{Process.pid}")
    FileUtils.mkdir_p(@test_dir)
    Handlers::Context.send(:remove_const, :CONTEXT_PATH) if Handlers::Context.const_defined?(:CONTEXT_PATH)
    Handlers::Context.const_set(:CONTEXT_PATH, @test_dir)
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  def test_read_returns_empty_string_for_empty_dir
    assert_equal '', Handlers::Context.read
  end

  def test_read_returns_empty_string_for_nonexistent_dir
    FileUtils.rm_rf(@test_dir)
    assert_equal '', Handlers::Context.read
  end

  def test_read_returns_concatenated_markdown
    File.write(File.join(@test_dir, 'a-policies.md'), '# Policies')
    File.write(File.join(@test_dir, 'b-modules.md'), '# Modules')

    result = Handlers::Context.read

    assert_includes result, '<!-- Source: a-policies.md -->'
    assert_includes result, '# Policies'
    assert_includes result, '<!-- Source: b-modules.md -->'
    assert_includes result, '# Modules'
  end

  def test_read_sorts_by_filename
    File.write(File.join(@test_dir, 'z-last.md'), 'last')
    File.write(File.join(@test_dir, 'a-first.md'), 'first')

    result = Handlers::Context.read

    assert result.index('a-first.md') < result.index('z-last.md')
  end

  def test_read_ignores_non_markdown_files
    File.write(File.join(@test_dir, 'readme.md'), '# OK')
    File.write(File.join(@test_dir, 'config.yaml'), 'not: markdown')

    result = Handlers::Context.read

    assert_includes result, '# OK'
    refute_includes result, 'not: markdown'
  end

  def test_read_strips_whitespace
    File.write(File.join(@test_dir, 'padded.md'), "  # Padded  \n\n")

    result = Handlers::Context.read

    assert_includes result, '# Padded'
  end
end
