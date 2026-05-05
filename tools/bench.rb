#!/usr/bin/env ruby

require "digest"
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

def expand_placeholders(command, vars)
  command.map do |part|
    text = part.dup
    vars.each do |key, value|
      text = text.gsub("{#{key}}", value.to_s)
    end
    text
  end
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

def run_command(command, repo_root)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  stdout, stderr, status = Open3.capture3(*command, chdir: repo_root)
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

options = {
  config: File.expand_path("bench.yml", __dir__),
  baseline: nil,
  check: true,
  bench: true,
  verbose: false
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

  opts.on("--verbose", "print each implementation's stdout/stderr") do
    options[:verbose] = true
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
    "repo_root" => repo_root
  }

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
        "%-12s %-2s %7ss  lines=%-8d sha256=%s",
        run.name,
        status,
        format_seconds(run.seconds),
        run.line_count,
        run.sha256
      )
    end
  end

  if options[:verbose]
    puts "verbose output:"
    runs.each do |run|
      puts "--- #{run.name} stdout ---"
      print run.stdout
      puts unless run.stdout.end_with?("\n")
      unless run.stderr.empty?
        puts "--- #{run.name} stderr ---"
        print run.stderr
        puts unless run.stderr.end_with?("\n")
      end
    end
  end

  all_success = runs.all? { |run| run.status.success? }
  outputs_match = !options[:check] || runs.all? { |run| run.status.success? && run.stdout == baseline.stdout }
  exit(all_success && outputs_match ? 0 : 1)
ensure
  tmp_input&.close!
end
