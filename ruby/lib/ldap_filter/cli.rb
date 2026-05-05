require "csv"
require "open3"
require "optparse"

class LdapFilterCommand
  SUPPORTED_FORMATS = %w[auto csv ltsv].freeze

  def self.run(argv, stdout: $stdout, stderr: $stderr)
    start_ns = monotonic_ns

    options, positional = parse_options(argv, stdout: stdout)
    filter = options[:filter] || positional[0]
    input_path = options[:input] || positional[1]
    raise ArgumentError, "filter and input path are required" unless filter && input_path

    stderr.puts phase_line("boot", start_ns, monotonic_ns)

    format = select_format(options[:format], input_path)
    opts = { keytype: :symbol }
    evaluator = LdapFilterEvaluator.new(filter, opts)

    stderr.puts phase_line("ready", start_ns, monotonic_ns)

    case format
    when "csv"
      process_rows(input_path, evaluator, stdout) do |io, row_yielder|
        CSV.new(io, headers: true, header_converters: :symbol).each do |row|
          row_yielder.call(row.to_h)
        end
      end
    when "ltsv"
      process_rows(input_path, evaluator, stdout) do |io, row_yielder|
        io.each_line do |line|
          row_yielder.call(LTSV.parse(line))
        end
      end
    else
      raise ArgumentError, "unsupported format: #{format}"
    end

    stderr.puts phase_line("done", start_ns, monotonic_ns)
  end

  def self.parse_options(argv, stdout:)
    options = { format: "auto" }
    parser = OptionParser.new do |opts|
      opts.banner = "Usage: ldap_filter [options] FILTER INPUT"

      opts.on("--filter FILTER", "LDAP search filter") do |value|
        options[:filter] = value
      end

      opts.on("--input PATH", "input log file") do |value|
        options[:input] = value
      end

      opts.on("--format FORMAT", SUPPORTED_FORMATS, "input format (default: auto)") do |value|
        options[:format] = value
      end

      opts.on("--help", "show help") do
        stdout.puts opts
        exit 0
      end
    end

    positional = parser.parse(argv)
    [options, positional]
  end

  def self.select_format(format, input_path)
    return format unless format == "auto"

    detect_format(input_path)
  end

  def self.detect_format(input_path)
    first_line = with_input_io(input_path) do |io|
      io.each_line.find { |line| !line.strip.empty? }
    end

    return "ltsv" if first_line&.include?("\t")

    "csv"
  end

  def self.process_rows(input_path, evaluator, stdout)
    with_input_io(input_path) do |io|
      row_yielder = lambda do |attrs|
        next unless evaluator.evaluate(attrs)

        stdout.puts attrs.inspect
      end

      yield(io, row_yielder)
    end
  end

  def self.with_input_io(input_path)
    if input_path.end_with?(".xz")
      stdin, stdout, stderr, wait_thr = Open3.popen3("xz", "-dc", input_path)
      stdin.close
      begin
        yield stdout
      ensure
        stdout.close unless stdout.closed?
        err = stderr.read
        stderr.close unless stderr.closed?
        status = wait_thr.value
        unless status.success?
          raise ArgumentError, "xz failed for #{input_path}: #{err.strip}"
        end
      end
    else
      File.open(input_path) do |io|
        yield io
      end
    end
  end

  def self.phase_line(phase, start_ns, now_ns)
    elapsed_ns = now_ns - start_ns
    "phase=#{phase} t=#{elapsed_ns} elapsed_ns=#{elapsed_ns}"
  end

  def self.monotonic_ns
    Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
  end
end
