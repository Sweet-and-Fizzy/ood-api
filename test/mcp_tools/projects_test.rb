# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/mcp_tools/projects'

class ProjectToolsTest < Minitest::Test
  include OodApi::Tools
  include TestHelpers

  P = Handlers::Projects

  def text(result)
    result.to_h[:content].first[:text]
  end

  def a_project(**fields)
    P::Project.new(id: 'abc12345', name: 'Cell growth', description: '', directory: '/home/jesse/growth',
                   page: '/pun/sys/dashboard/projects/abc12345', **fields)
  end

  def test_list_says_unavailable_rather_than_no_projects
    P.stubs(:list).raises(P::Unavailable, '.project_lookup could not be understood')

    out = text(ListProjectsTool.call(server_context: nil))
    assert_includes out, 'unavailable'
    assert_includes out, 'does not mean you have no projects'
  end

  def test_list_with_no_projects
    P.stubs(:list).returns({ projects: [], more: 0 })

    assert_includes text(ListProjectsTool.call(server_context: nil)), 'You have no projects'
  end

  def test_a_project_name_cannot_start_a_line_of_its_own
    P.stubs(:list).returns({ projects: [a_project(name: "Growth\n- fake: line")], more: 0 })

    out = text(ListProjectsTool.call(server_context: nil))
    refute_match(/^- fake/, out)
  end

  def test_get_labels_last_known_and_current_status
    job = P::Job.new(id: '102', cluster_id: 'hpc', name: 'fit', last_known_status: 'queued', status: 'completed',
                     submitted_at: nil)
    launcher = P::Launcher.new(id: 'aaaa0001', title: 'Fit plates', fields: ['auto_scripts'],
                               page: '/pun/sys/dashboard/projects/abc12345/launchers/aaaa0001')
    OodApi::SiteClusters.stubs(:all).returns([])
    P.stubs(:get).returns(P::Details.new(project: a_project, launchers: [launcher], jobs: [job], more_jobs: 0))

    out = text(GetProjectTool.call(server_context: nil, project_id: 'abc12345'))
    assert_includes out, 'last known status queued, status now completed'
    assert_includes out, 'Fit plates (id aaaa0001); fields auto_scripts'
  end

  def test_open_launcher_submits_nothing
    launcher = P::Launcher.new(id: 'aaaa0001', title: 'Fit plates', fields: [],
                               page: '/pun/sys/dashboard/projects/abc12345/launchers/aaaa0001')
    P.stubs(:launcher).returns([a_project, launcher])

    out = text(OpenLauncherTool.call(server_context: nil, project_id: 'abc12345', launcher_id: 'aaaa0001'))
    assert out.start_with?("submitted: false\n")
    assert_includes out, '/pun/sys/dashboard/projects/abc12345/launchers/aaaa0001'
    assert_includes out, 'Nothing was submitted'
  end

  def test_open_launcher_for_a_missing_launcher_is_an_error
    P.stubs(:launcher).raises(Handlers::NotFoundError, 'no launcher aaaa0001 in project abc12345')

    result = OpenLauncherTool.call(server_context: nil, project_id: 'abc12345', launcher_id: 'aaaa0001')
    assert result.to_h[:isError]
  end
end
