# frozen_string_literal: true

require 'shellwords'
require 'time'
require_relative 'files'

module Handlers
  # What a job's scheduler knows about it beyond the portable status: its own
  # word for the state, which tells failed, timed-out and out-of-memory jobs
  # apart where the portable status says only "completed"; the reason it
  # ended or is waiting; the directory it runs in; its script; and, for
  # Slurm, the files its output and errors go to.
  #
  # Slurm does not report a job's output files to ood_core, so they are
  # worked out the way sbatch does: from the script's #SBATCH --output and
  # --error lines, or Slurm's default of slurm-<id>.out in the working
  # directory. Options given to sbatch on its command line override the
  # script, so each path says where it came from. The script is read through
  # the same checks as read_file.
  module JobDetails
    SCRIPT_LIMIT = 64 * 1024
    EMPTY = ['', '(null)', 'n/a', 'none'].freeze

    module_function

    # @param info [OodCore::Job::Info]
    # @param adapter [String, Symbol, nil] the cluster's job adapter
    # @return [Hash{Symbol => String}] only the details that are known
    def of(info, adapter)
      native = info.native.is_a?(Hash) ? info.native : {}
      details = {
        native_state:   value(native[:state])&.downcase,
        reason:         value(native[:reason]),
        expected_start: expected_start(info, native),
        work_dir:       value(native[:work_dir]),
        script:         value(native[:command])
      }
      details.merge!(slurm_files(info, native, details)) if adapter.to_s == 'slurm' && details[:work_dir]
      details.compact
    end

    # Slurm's estimate of when a waiting job will start, in UTC; nothing for
    # a job that is not waiting or has no estimate. squeue prints it in the
    # local time zone of the process that ran it, which is this one, with
    # no zone marked, so it is read as local time and converted.
    def expected_start(info, native)
      return nil unless info.status.queued? || info.status.queued_held?

      text = value(native[:start_time])
      return nil unless text&.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?\z/)

      Time.strptime(text, text.length == 16 ? '%Y-%m-%dT%H:%M' : '%Y-%m-%dT%H:%M:%S').getutc.iso8601
    rescue ArgumentError
      nil
    end

    def value(raw)
      text = raw.to_s.scrub.strip
      EMPTY.include?(text.downcase) ? nil : text
    end

    def slurm_files(info, native, details)
      named = details[:script] ? directives(details[:script]) : {}
      array = value(native[:array_task_id])
      default = array ? 'slurm-%A_%a.out' : 'slurm-%j.out'
      output = named[:output] || default
      {
        output_path:   absolute(expand(output, info, native), details[:work_dir]),
        output_source: named[:output] ? 'job script' : 'Slurm default',
        error_path:    absolute(expand(named[:error] || output, info, native), details[:work_dir]),
        error_source:  error_source(named)
      }
    end

    def error_source(named)
      return 'job script' if named[:error]

      named[:output] ? 'same as output, from the job script' : 'Slurm default'
    end

    # The --output and --error a batch script names. sbatch reads #SBATCH
    # lines only until the first command, and so does this.
    def directives(script)
      text = Handlers::Files.read(path: script, max_size: SCRIPT_LIMIT)
      found = {}
      text.each_line.with_index do |line, index|
        line = line.strip
        next if index.zero? && line.start_with?('#!')
        break unless line.empty? || line.start_with?('#')
        next unless line.start_with?('#SBATCH')

        options(line.delete_prefix('#SBATCH'), found)
      end
      found
    rescue StandardError
      {}
    end

    FLAGS = { output: ['--output', '-o'], error: ['--error', '-e'] }.freeze

    def options(rest, found)
      words = begin
        Shellwords.split(rest)
      rescue ArgumentError
        rest.split
      end
      words.each_with_index do |word, i|
        FLAGS.each do |key, (long, short)|
          given = flag_value(word, words[i + 1], long, short)
          found[key] = given if given
        end
      end
    end

    # The value of one option in its three spellings: --output=FILE,
    # --output FILE or -o FILE, and -oFILE.
    def flag_value(word, following, long, short)
      return word.delete_prefix("#{long}=") if word.start_with?("#{long}=")
      return following if [long, short].include?(word)
      return nil unless word.start_with?(short) && !word.start_with?('--') && word.length > short.length

      word.delete_prefix(short)
    end

    # Fills in the filename patterns Slurm documents that are known here;
    # any other pattern is left as written.
    def expand(pattern, info, native)
      known = {
        'j' => info.id,
        'x' => info.job_name,
        'u' => value(native[:user]) || info.job_owner,
        'A' => value(native[:array_job_id]) || info.id,
        'a' => value(native[:array_task_id])
      }
      pattern.gsub(/%(%|[jxuAa])/) do
        token = Regexp.last_match(1)
        next '%' if token == '%'

        known[token].nil? ? "%#{token}" : known[token].to_s
      end
    end

    def absolute(path, work_dir)
      path.start_with?('/') ? path : File.join(work_dir, path)
    end
  end
end
