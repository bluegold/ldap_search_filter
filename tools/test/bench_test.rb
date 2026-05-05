require "minitest/autorun"
require "open3"
require "psych"
require "tmpdir"

class BenchTest < Minitest::Test
  def run_bench(config_path:, input_path:, args: [])
    bench = File.expand_path("../bench.rb", __dir__)
    Open3.capture3(
      "ruby",
      bench,
      "--config",
      config_path,
      "--input",
      input_path,
      "--filter",
      "(host=*)",
      *args
    )
  end

  def write_config(path, build_log_path)
    shared_build = [
      "ruby",
      "-e",
      "File.open(#{build_log_path.inspect}, 'a'){|f| f.puts('shared')}"
    ]
    distinct_build = [
      "ruby",
      "-e",
      "File.open(#{build_log_path.inspect}, 'a'){|f| f.puts('distinct')}"
    ]
    benchmark_command = [
      "ruby",
      "-e",
      "puts '{:host=>\"example.com\"}'"
    ]

    config = {
      "implementations" => [
        {
          "name" => "short",
          "build" => {
            "command" => shared_build
          },
          "command" => benchmark_command
        },
        {
          "name" => "much-longer-name",
          "build" => {
            "command" => shared_build
          },
          "command" => benchmark_command
        },
        {
          "name" => "other",
          "build" => {
            "command" => distinct_build
          },
          "command" => benchmark_command
        }
      ]
    }

    File.write(path, Psych.dump(config))
  end

  def test_build_commands_are_deduplicated_by_signature
    Dir.mktmpdir("ldf-bench-test") do |dir|
      input_path = File.join(dir, "sample.ltsv")
      config_path = File.join(dir, "bench.yml")
      build_log_path = File.join(dir, "build.log")

      File.write(input_path, "host:example.com\n", mode: "w")
      write_config(config_path, build_log_path)

      stdout, stderr, status = run_bench(
        config_path: config_path,
        input_path: input_path,
        args: ["--no-check", "--no-bench"]
      )

      assert status.success?, stderr
      assert_equal ["shared", "distinct"], File.read(build_log_path).lines.map(&:strip)
      assert_includes stdout, "build:"
      assert_match(/\Ashort, much-longer-name\s+ok\z/, stdout.each_line.find { |line| line.include?("short, much-longer-name") }.strip)
      assert_match(/\Aother\s+ok\z/, stdout.each_line.find { |line| line.start_with?("other") }.strip)
    end
  end

  def test_benchmark_rows_share_the_same_status_column
    Dir.mktmpdir("ldf-bench-test") do |dir|
      input_path = File.join(dir, "sample.ltsv")
      config_path = File.join(dir, "bench.yml")
      build_log_path = File.join(dir, "build.log")

      File.write(input_path, "host:example.com\n", mode: "w")
      write_config(config_path, build_log_path)

      stdout, stderr, status = run_bench(
        config_path: config_path,
        input_path: input_path,
        args: ["--no-check"]
      )

      assert status.success?, stderr

      benchmark_lines = stdout.each_line.drop_while { |line| line != "benchmark:\n" }.drop(1).take(3)
      assert_equal 3, benchmark_lines.size

      status_columns = benchmark_lines.map { |line| line.index("ok") }
      assert_equal [status_columns.first] * status_columns.size, status_columns
    end
  end

  def test_verbose_outputs_stdout_only
    Dir.mktmpdir("ldf-bench-test") do |dir|
      input_path = File.join(dir, "sample.ltsv")
      config_path = File.join(dir, "bench.yml")
      build_log_path = File.join(dir, "build.log")

      File.write(input_path, "host:example.com\n", mode: "w")
      config = {
        "implementations" => [
          {
            "name" => "short",
            "build" => {
              "command" => [
                "ruby",
                "-e",
                "File.open(#{build_log_path.inspect}, 'a'){|f| f.puts('shared')}"
              ]
            },
            "command" => [
              "ruby",
              "-e",
              "STDERR.puts('trace:short'); puts '{:host=>\"example.com\"}'"
            ]
          }
        ]
      }
      File.write(config_path, Psych.dump(config))

      stdout, stderr, status = run_bench(
        config_path: config_path,
        input_path: input_path,
        args: ["--no-check", "--no-bench", "--verbose"]
      )

      assert status.success?, stderr
      assert_includes stdout, "verbose stdout:"
      assert_includes stdout, "--- short stdout ---"
      assert_includes stdout, "example.com"
      refute_includes stdout, "trace:short"
    end
  end

  def test_timestamp_summary_is_indented_under_benchmark_rows
    Dir.mktmpdir("ldf-bench-test") do |dir|
      input_path = File.join(dir, "sample.ltsv")
      config_path = File.join(dir, "bench.yml")
      build_log_path = File.join(dir, "build.log")

      File.write(input_path, "host:example.com\n", mode: "w")
      config = {
        "implementations" => [
          {
            "name" => "short",
            "build" => {
              "command" => [
                "ruby",
                "-e",
                "File.open(#{build_log_path.inspect}, 'a'){|f| f.puts('shared')}"
              ]
            },
            "command" => [
              "ruby",
              "-e",
              "STDERR.puts('phase=boot t=1 elapsed_ns=1'); STDERR.puts('phase=ready t=2 elapsed_ns=2'); STDERR.puts('phase=done t=3 elapsed_ns=3'); puts '{:host=>\"example.com\"}'"
            ]
          }
        ]
      }
      File.write(config_path, Psych.dump(config))

      stdout, stderr, status = run_bench(
        config_path: config_path,
        input_path: input_path,
        args: ["--no-check", "--timestamp"]
      )

      assert status.success?, stderr
      assert_includes stdout, "benchmark:"
      benchmark_line = stdout.each_line.find { |line| line.start_with?("short") }
      assert benchmark_line
      parse_line = stdout.each_line.find { |line| line.start_with?("  parse") }
      processing_line = stdout.each_line.find { |line| line.start_with?("  processing") }
      assert parse_line
      assert processing_line
      assert_match(/\A  parse\s+\d+\.\d{3}ms\z/, parse_line.chomp)
      assert_match(/\A  processing\s+\d+\.\d{3}ms\z/, processing_line.chomp)
      refute_includes stdout, "  done"
    end
  end
end
