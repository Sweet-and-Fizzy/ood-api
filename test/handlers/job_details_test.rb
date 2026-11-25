# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../../app/handlers/job_details'

class HandlersJobDetailsTest < Minitest::Test
  include TestHelpers

  def setup
    @dir = File.join(Dir.tmpdir, "ood-job-details-#{Process.pid}-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(@dir)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def script(text)
    path = File.join(@dir, 'run.sbatch')
    File.write(path, text)
    path
  end

  def failed_job(native = {})
    mock_job_info(id: '13', job_name: 'growth', job_owner: 'jesse', status: :completed,
                  native: { state: 'FAILED', reason: 'NonZeroExitCode', work_dir: @dir }.merge(native))
  end

  def test_a_failed_slurm_job_reports_its_state_reason_and_the_output_file_its_script_names
    path = script("#!/bin/bash\n#SBATCH --job-name=growth\n#SBATCH --output=logs/%x-%j.out\npython3 analyse.py\n")
    details = Handlers::JobDetails.of(failed_job(command: path), 'slurm')

    assert_equal 'failed', details[:native_state]
    assert_equal 'NonZeroExitCode', details[:reason]
    assert_equal @dir, details[:work_dir]
    assert_equal path, details[:script]
    assert_equal File.join(@dir, 'logs/growth-13.out'), details[:output_path]
    assert_equal 'job script', details[:output_source]
    assert_equal details[:output_path], details[:error_path]
    assert_equal 'same as output, from the job script', details[:error_source]
  end

  def test_short_and_separate_forms_are_read_and_lines_after_the_first_command_are_not
    path = script("#!/bin/sh\n#SBATCH -o /scratch/out-%u.txt\n#SBATCH -eerr-%%-%j.txt\n\n" \
                  "srun hostname\n#SBATCH --output=ignored.out\n")
    details = Handlers::JobDetails.of(failed_job(command: path, user: 'jesse'), 'slurm')

    assert_equal '/scratch/out-jesse.txt', details[:output_path]
    assert_equal File.join(@dir, 'err-%-13.txt'), details[:error_path]
    assert_equal 'job script', details[:error_source]
  end

  def test_with_no_output_named_slurms_default_is_given_and_said_to_be_the_default
    details = Handlers::JobDetails.of(failed_job(command: script("#!/bin/bash\nsleep 1\n")), 'slurm')

    assert_equal File.join(@dir, 'slurm-13.out'), details[:output_path]
    assert_equal 'Slurm default', details[:output_source]
    assert_equal 'Slurm default', details[:error_source]
  end

  def test_an_array_task_uses_slurms_array_default
    details = Handlers::JobDetails.of(failed_job(array_job_id: '40', array_task_id: '3'), 'slurm')

    assert_equal File.join(@dir, 'slurm-40_3.out'), details[:output_path]
  end

  def test_a_script_the_site_does_not_allow_reading_falls_back_to_the_default
    Handlers::Files.stubs(:read).raises(Handlers::ForbiddenError, 'Access denied')
    details = Handlers::JobDetails.of(failed_job(command: script("#SBATCH --output=secret.out\n")), 'slurm')

    assert_equal File.join(@dir, 'slurm-13.out'), details[:output_path]
    assert_equal 'Slurm default', details[:output_source]
  end

  def test_empty_values_are_left_out_and_other_schedulers_get_no_output_files
    details = Handlers::JobDetails.of(failed_job(reason: 'None', command: '(null)'), 'pbspro')

    assert_equal({ native_state: 'failed', work_dir: @dir }, details)
  end

  def test_a_job_with_no_native_data_has_no_details
    assert_empty Handlers::JobDetails.of(mock_job_info(id: '1'), 'slurm')
  end
end
