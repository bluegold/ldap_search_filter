#!/usr/bin/env ruby

require "digest"
require "find"
require "open3"
require "optparse"
require "psych"
require "shellwords"
require "tempfile"

Result = Struct.new(
  :name,
  :stdout,
  :stderr,
  :status,
  :seconds,
  :sha256,
  :line_count,
  keyword_init: true
)

TimestampPoint = Struct.new(
  :phase,
  :elapsed_ns,
  keyword_init: true
)

def repo_root
  File.expand_path("..", __dir__)
end

def load_config(path)
  data = Psych.safe_load(
    File.read(path),
    permitted_classes: [],
    permitted_symbols: [],
    aliases: true
  )
  unless data.is_a?(Hash)
    raise ArgumentError, "config must be a mapping"
  end
  data
end

def fetch_hash_value(hash, key)
  return hash[key] if hash.key?(key)
  return hash[key.to_sym] if hash.key?(key.to_sym)
  nil
end

def normalize_command(command)
  case command
  when Array
    command.map(&:to_s)
  when String
    Shellwords.split(command)
  else
    raise ArgumentError, "command must be an array or string"
  end
end

def normalize_build(build)
  case build
  when Hash
    command = fetch_hash_value(build, "command")
    unless command
      raise ArgumentError, "build must include command"
    end

    sources = fetch_hash_value(build, "sources")
    sources =
      case sources
      when nil
        []
      when Array
        sources.map(&:to_s)
      else
        [sources.to_s]
      end

    {
      command: normalize_command(command),
      cwd: fetch_hash_value(build, "cwd")&.to_s,
      target: fetch_hash_value(build, "target")&.to_s,
      size_target: fetch_hash_value(build, "size_target")&.to_s,
      sources: sources
    }
  else
    {
      command: normalize_command(build),
      cwd: nil,
      target: nil,
      size_target: nil,
      sources: []
    }
  end
end

def expand_placeholders(command, vars)
  command.map do |part|
    text = part.dup
    vars.each do |key, value|
      text = text.gsub("{#{key}}", value.to_s)
    end
    next if text.empty?

    text
  end.compact
end

def prepare_input(path)
  abs_path = File.expand_path(path, repo_root)
  unless File.exist?(abs_path)
    raise ArgumentError, "input file not found: #{path}"
  end

  return [abs_path, nil] unless abs_path.end_with?(".xz")

  tmp = Tempfile.new(["ldf-input", File.basename(abs_path, ".xz")])
  tmp.binmode

  stdin, stdout, stderr, wait_thr = Open3.popen3("xz", "-dc", abs_path)
  stdin.close
  begin
    IO.copy_stream(stdout, tmp)
  ensure
    stdout.close
  end

  err = stderr.read
  stderr.close
  status = wait_thr.value
  unless status.success?
    tmp.close!
    raise ArgumentError, "xz failed for #{path}: #{err.strip}"
  end

  tmp.flush
  tmp.rewind
  [tmp.path, tmp]
end

def run_command(command, repo_root, chdir: repo_root)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stdout, stderr, status = Open3.capture3(*command, chdir: chdir)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

  Result.new(
    stdout: stdout,
    stderr: stderr,
    status: status,
    seconds: elapsed,
    sha256: Digest::SHA256.hexdigest(stdout),
    line_count: stdout.each_line.count,
    name: nil
  )
end

def build_summary_line(names, status, width)
  label = names.join(", ")
  format("%-#{width}s %s", label, status)
end

def binary_size_label(bytes)
  units = %w[B KiB MiB GiB TiB]
  value = bytes.to_f
  unit = units.shift

  while value >= 1024.0 && !units.empty?
    value /= 1024.0
    unit = units.shift
  end

  if unit == "B"
    "#{bytes}B"
  else
    format("%.1f%s", value, unit)
  end
end

def display_width(implementations, build_specs)
  run_width = implementations.map { |impl| fetch_hash_value(impl, "name").to_s.length }.max || 0
  build_width = build_specs.values.flat_map { |spec| spec[:names] }.map(&:length).max || 0
  [12, run_width, build_width].max
end

def build_spec_key(spec)
  [
    spec[:cwd],
    spec[:target],
    spec[:size_target],
    spec[:sources].sort,
    spec[:command]
  ].flatten.join("\u0000")
end

def format_seconds(seconds)
  format("%.3f", seconds)
end

def excerpt(text, limit: 10)
  lines = text.each_line.take(limit)
  return "" if lines.empty?

  body = lines.join
  body += "\n... (truncated)\n" if text.each_line.count > limit
  body
end

def parse_timestamp_points(stderr)
  points = []
  stderr.each_line do |line|
    match = /\Aphase=([a-zA-Z0-9_:-]+)\b.*\belapsed_ns=(\d+)\b/.match(line)
    next unless match

    points << TimestampPoint.new(
      phase: match[1],
      elapsed_ns: match[2].to_i
    )
  end
  points
end

def format_timestamp_point(point)
  elapsed_ms = point.elapsed_ns / 1_000_000.0
  label =
    case point.phase
    when "boot"
      "boot"
    when "ready"
      "parse"
    when "done"
      "processing"
    else
      point.phase
    end

  format("  %-10s %10.3fms", label, elapsed_ms)
end

def build_target_path(spec, repo_root)
  return nil unless spec[:target] && !spec[:target].empty?

  chdir = spec[:cwd] ? File.expand_path(spec[:cwd], repo_root) : repo_root
  File.expand_path(spec[:target], chdir)
end

def build_size_path(spec, repo_root)
  candidate = spec[:size_target] && !spec[:size_target].empty? ? spec[:size_target] : spec[:target]
  return nil unless candidate && !candidate.empty?

  chdir = spec[:cwd] ? File.expand_path(spec[:cwd], repo_root) : repo_root
  File.expand_path(candidate, chdir)
end

def build_source_paths(spec, repo_root)
  chdir = spec[:cwd] ? File.expand_path(spec[:cwd], repo_root) : repo_root
  spec[:sources].flat_map do |source|
    pattern = File.expand_path(source, chdir)
    matches = Dir.glob(pattern, File::FNM_EXTGLOB | File::FNM_DOTMATCH)
    if matches.empty?
      raise ArgumentError, "build source not found: #{source}"
    end

    matches.select { |path| File.file?(path) }
  end.uniq
end

def build_size_bytes(spec, repo_root)
  path = build_size_path(spec, repo_root)
  return nil unless path && File.exist?(path)

  if File.directory?(path)
    total = 0
    Find.find(path) do |entry|
      next unless File.file?(entry)

      total += File.size(entry)
    end
    total
  else
    File.size(path)
  end
end

def build_stale?(spec, repo_root)
  return true if spec[:target].nil? || spec[:target].empty? || spec[:sources].empty?

  target_path = build_target_path(spec, repo_root)
  return true unless File.exist?(target_path)

  target_mtime = File.mtime(target_path)
  build_source_paths(spec, repo_root).each do |source_path|
    return true unless File.exist?(source_path)
    return true if File.mtime(source_path) > target_mtime
  end

  false
end

def build_status_text(status, spec, repo_root)
  size_bytes = build_size_bytes(spec, repo_root)
  size_text = size_bytes ? " size=#{binary_size_label(size_bytes)}" : ""
  "#{status}#{size_text}"
end

def detect_format(input_path)
  base = File.basename(input_path)
  return "csv" if base.match?(/\.csv(?:\.xz)?\z/)
  return "ltsv" if base.match?(/\.ltsv(?:\.xz)?\z/)

  "ltsv"
end

options = {
  config: File.expand_path("bench.yml", __dir__),
  baseline: nil,
  check: true,
  jit: nil,
  bench: true,
  verbose: false,
  timestamp: false
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby tools/bench.rb --filter FILTER --input PATH [options]"

  opts.on("--config PATH", "implementation config YAML (default: tools/bench.yml)") do |value|
    options[:config] = File.expand_path(value, repo_root)
  end

  opts.on("--filter FILTER", "LDAP search filter to apply") do |value|
    options[:filter] = value
  end

  opts.on("--input PATH", "input log file (.xz is accepted)") do |value|
    options[:input] = value
  end

  opts.on("--jit", "run implementations with JIT enabled") do
    raise ArgumentError, "conflicting JIT flags" if options[:jit] == false

    options[:jit] = true
  end

  opts.on("--no-jit", "run implementations with JIT disabled") do
    raise ArgumentError, "conflicting JIT flags" if options[:jit] == true

    options[:jit] = false
  end

  opts.on("--baseline NAME", "implementation name used as the comparison baseline") do |value|
    options[:baseline] = value
  end

  opts.on("--only NAME", "run only one implementation (repeatable)") do |value|
    (options[:only] ||= []) << value
  end

  opts.on("--[no-]check", "compare stdout against the baseline (default: on)") do |value|
    options[:check] = value
  end

  opts.on("--[no-]bench", "print elapsed time (default: on)") do |value|
    options[:bench] = value
  end

  opts.on("--verbose", "print each implementation's stdout") do
    options[:verbose] = true
  end

  opts.on("--timestamp", "print each implementation's stderr") do
    options[:timestamp] = true
  end

  opts.on("--help", "show help") do
    puts opts
    exit 0
  end
end

parser.parse!

unless options[:filter] && options[:input]
  warn parser.to_s
  exit 1
end

config = load_config(options[:config])
implementations = fetch_hash_value(config, "implementations")
unless implementations.is_a?(Array) && !implementations.empty?
  raise ArgumentError, "config must include at least one implementation"
end

if options[:only]
  selected = options[:only]
  implementations = implementations.select do |impl|
    selected.include?(fetch_hash_value(impl, "name").to_s)
  end
end

if implementations.empty?
  raise ArgumentError, "no implementations selected"
end

  baseline_name = options[:baseline] || fetch_hash_value(implementations.first, "name").to_s
  input_path, tmp_input = prepare_input(options[:input])

begin
  vars = {
    "filter" => options[:filter],
    "input" => input_path,
    "format" => detect_format(options[:input]),
    "jit_flag" => options[:jit].nil? ? "" : (options[:jit] ? "--jit" : "--no-jit"),
    "repo_root" => repo_root
  }

  build_specs = {}
  implementations.each do |impl|
    name = fetch_hash_value(impl, "name").to_s
    build = fetch_hash_value(impl, "build")
    next unless build

    spec = normalize_build(build)
    key = build_spec_key(spec)
    build_specs[key] ||= spec.merge(names: [])
    build_specs[key][:names] << name
  end

  unless build_specs.empty?
    puts "build:"
  end
  width = display_width(implementations, build_specs)
  build_specs.each_value do |spec|
    chdir = spec[:cwd] ? File.expand_path(spec[:cwd], repo_root) : repo_root
    if build_stale?(spec, repo_root)
      result = run_command(spec[:command], repo_root, chdir: chdir)
      unless result.status.success?
        puts "build: failed"
        puts "command: #{spec[:command].join(' ')}"
        puts "stdout"
        puts excerpt(result.stdout)
        puts "stderr"
        puts excerpt(result.stderr)
        exit 1
      end

      puts build_summary_line(spec[:names], build_status_text("ok", spec, repo_root), width)
    else
      puts build_summary_line(spec[:names], build_status_text("up to date", spec, repo_root), width)
    end
  end

  runs = implementations.map do |impl|
    name = fetch_hash_value(impl, "name").to_s
    command = normalize_command(fetch_hash_value(impl, "command"))
    command = expand_placeholders(command, vars)
    result = run_command(command, repo_root)
    result.name = name
    result
  end

  baseline = runs.find { |run| run.name == baseline_name }
  unless baseline
    available = runs.map(&:name).join(", ")
    raise ArgumentError, "baseline #{baseline_name.inspect} not found among: #{available}"
  end

  puts "input: #{options[:input]}"
  puts "filter: #{options[:filter]}"
  puts "baseline: #{baseline.name}"
  puts "jit: #{options[:jit].nil? ? 'default' : (options[:jit] ? 'on' : 'off')}"

  if options[:check]
    mismatches = runs.reject { |run| run.stdout == baseline.stdout && run.status.success? && baseline.status.success? }
    if mismatches.empty?
      puts "check: ok"
    else
      puts "check: mismatch"
      puts "baseline sha256=#{baseline.sha256} lines=#{baseline.line_count}"
      mismatches.each do |run|
        puts "#{run.name}: status=#{run.status.exitstatus} sha256=#{run.sha256} lines=#{run.line_count}"
        unless run.stderr.empty?
          puts "stderr[#{run.name}]"
          puts excerpt(run.stderr)
        end
      end
    end
  end

  if options[:bench]
    puts "benchmark:"
    runs.each do |run|
      status = run.status.success? ? "ok" : "ng"
      puts format(
        "%-#{width}s %-2s %7ss  lines=%-8d sha256=%s",
        run.name,
        status,
        format_seconds(run.seconds),
        run.line_count,
        run.sha256
      )
      next unless options[:timestamp]

      parse_timestamp_points(run.stderr).each do |point|
        puts format_timestamp_point(point)
      end
    end
  end

  if options[:verbose]
    puts "verbose stdout:"
    runs.each do |run|
      puts "--- #{run.name} stdout ---"
      print run.stdout
      puts unless run.stdout.end_with?("\n")
    end
  end

  all_success = runs.all? { |run| run.status.success? }
  outputs_match = !options[:check] || runs.all? { |run| run.status.success? && run.stdout == baseline.stdout }
  exit(all_success && outputs_match ? 0 : 1)
ensure
  tmp_input&.close!
end
