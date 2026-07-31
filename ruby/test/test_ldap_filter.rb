require_relative "test_helper"

require "open3"
require "rbconfig"

class ParserTest < Minitest::Test
  def test_public_api_parses_and_evaluates
    rule = LdapFilter.parse("(host=example.com)")

    assert_equal true, LdapFilter.evaluate(rule, "host" => "example.com")
    assert_equal false, LdapFilter.evaluate(rule, "host" => "example.org")
  end

  def test_parses_wildcard_filter
    parser = LdapFilter::Parser.new
    item = parser.parse("(host=www.*)")
    assert_kind_of LdapFilter::Item, item
    assert_equal "=", item.filtertype
    assert_equal "host", item.attr
    assert_equal "www.*", item.value
    assert_kind_of Regexp, item.regex
  end

  def test_parses_presence_filter
    parser = LdapFilter::Parser.new
    item = parser.parse("(host=*)")
    assert_kind_of LdapFilter::Item, item
    assert_equal "*", item.value
    assert_nil item.regex
  end

  def test_wildcard_matches_the_entire_value
    evaluator = LdapFilter::Evaluator.new("(host=www.*)")

    assert_equal true, evaluator.evaluate("host" => "www.example.com")
    assert_equal false, evaluator.evaluate("host" => "xwww.example.com")
  end

  def test_escaped_star_is_a_literal
    evaluator = LdapFilter::Evaluator.new("(host=foo\\2abar)")

    assert_equal true, evaluator.evaluate("host" => "foo*bar")
    assert_equal false, evaluator.evaluate("host" => "foo123bar")
  end

  def test_decodes_utf8_escaped_bytes
    evaluator = LdapFilter::Evaluator.new("(name=\\e3\\81\\82)")

    assert_equal true, evaluator.evaluate("name" => "あ")
  end

  def test_rejects_invalid_utf8_escape
    assert_raises(LdapFilter::Error) { LdapFilter::Parser.new.parse("(name=\\ff)") }
  end

  def test_rejects_trailing_input_and_empty_filter
    assert_raises(LdapFilter::Error) { LdapFilter::Parser.new.parse("(host=ok)(other=value)") }
    assert_raises(LdapFilter::Error) { LdapFilter::Parser.new.parse("") }
  end

  def test_allows_empty_assertion_value
    item = LdapFilter::Parser.new.parse("(host=)")

    assert_equal "", item.value
  end

  def test_not_requires_exactly_one_filter
    assert_raises(LdapFilter::Error) { LdapFilter::Parser.new.parse("(!(host=a)(host=b))") }
  end
end

class EvaluatorTest < Minitest::Test
  def test_evaluates_logical_expression
    evaluator = LdapFilter::Evaluator.new("(&(host=www.*)(status=200))", keytype: :symbol)

    attrs = {
      host: "www.example.com",
      status: "200"
    }

    assert_equal true, evaluator.evaluate(attrs)
  end

  def test_evaluates_presence_filter
    evaluator = LdapFilter::Evaluator.new("(host=*)", keytype: :symbol)

    assert_equal true, evaluator.evaluate(host: "example")
    assert_equal false, evaluator.evaluate({})
  end

  def test_evaluation_always_returns_boolean_for_missing_or_invalid_values
    assert_equal false, LdapFilter::Evaluator.new("(name~=john)").evaluate({})
    assert_equal false, LdapFilter::Evaluator.new("(age>=18)").evaluate("age" => 20)
    assert_equal false, LdapFilter::Evaluator.new("(name=jo*)").evaluate("name" => 123)
  end

  def test_evaluator_accepts_keyword_attributes
    evaluator = LdapFilter::Evaluator.new("(host=example.com)", keytype: :symbol)

    assert_equal true, evaluator.evaluate(host: "example.com")
  end

  def test_keytype_controls_only_filter_attribute_names
    attrs = { "host" => "example.com" }
    filter = LdapFilter.parse("(host=example.com)", keytype: :string)

    assert_equal true, LdapFilter.evaluate(filter, attrs)
    assert_equal false, LdapFilter.evaluate(filter, host: "example.com")
    assert_equal({ "host" => "example.com" }, attrs)
  end

  def test_parser_rejects_unknown_keytype
    assert_raises(ArgumentError) do
      LdapFilter::Parser.new(keytype: :integer)
    end
  end

  def test_parser_returns_ast_without_storing_result
    parser = LdapFilter::Parser.new

    assert_equal false, parser.respond_to?(:result)
    assert_instance_of LdapFilter::Item, parser.parse("(host=example.com)")
  end

  def test_ltsv_uses_string_keys_by_default
    assert_equal({ "host" => "example.com" }, LdapFilter::Ltsv.parse_line("host:example.com"))
    assert_equal({ host: "example.com" }, LdapFilter::Ltsv.parse_line("host:example.com", symbolize_keys: true))
  end

  def test_evaluator_rejects_unsupported_filter_objects
    assert_raises(ArgumentError) { LdapFilter::Evaluator.new(Object.new) }
  end

  def test_logger_receives_evaluation_messages
    messages = []
    logger = Object.new
    logger.define_singleton_method(:info) { |message| messages << message }

    rule = LdapFilter::Parser.new.parse("(host=example.com)")
    LdapFilter::Evaluator.new(rule, logger: logger).evaluate("host" => "example.com")

    assert_equal 2, messages.length
    assert_includes messages.first, "host"
    assert_equal "result: true", messages.last
  end
end

class FilterSemanticsTest < Minitest::Test
  def test_parser_builds_logical_nodes
    assert_instance_of LdapFilter::And, LdapFilter::Parser.new.parse("(&(a=1)(b=2))")
    assert_instance_of LdapFilter::Or, LdapFilter::Parser.new.parse("(|(a=1)(b=2))")
    assert_instance_of LdapFilter::Not, LdapFilter::Parser.new.parse("(!(a=1))")
  end

  def test_parser_builds_symbol_attributes_when_requested
    item = LdapFilter::Parser.new(keytype: :symbol).parse("(host=example.com)")

    assert_equal :host, item.attr
  end

  def test_parser_rejects_empty_logical_lists_and_unbalanced_filters
    ["(&)", "(|)", "(!)", "(a=1", "a=1)", "((a=1))"].each do |filter|
      assert_raises(LdapFilter::Error, filter) do
        LdapFilter::Parser.new.parse(filter)
      end
    end
  end

  def test_parser_rejects_malformed_escape_sequences
    ["(a=\\0)", "(a=\\gg)", "(a=trailing\\)"].each do |filter|
      assert_raises(LdapFilter::Error, filter) do
        LdapFilter::Parser.new.parse(filter)
      end
    end
  end

  def test_parser_decodes_escaped_parentheses_and_backslash
    item = LdapFilter::Parser.new.parse("(value=left\\28middle\\29\\5c right)")

    assert_equal "left(middle)\\ right", item.value
  end

  def test_evaluates_or_and_not
    assert_equal true, LdapFilter.evaluate("(|(status=404)(status=500))", "status" => "500")
    assert_equal false, LdapFilter.evaluate("(|(status=404)(status=500))", "status" => "200")
    assert_equal true, LdapFilter.evaluate("(!(status=200))", "status" => "404")
    assert_equal false, LdapFilter.evaluate("(!(status=200))", "status" => "200")
  end

  def test_evaluates_all_comparison_operators
    assert_equal true, LdapFilter.evaluate("(name~=john)", "name" => "jonn")
    assert_equal false, LdapFilter.evaluate("(name~=john)", "name" => "smith")
    assert_equal true, LdapFilter.evaluate("(name~=abcd)", "name" => "ab")
    assert_equal false, LdapFilter.evaluate("(name~=abcd)", "name" => "a")
    assert_equal true, LdapFilter.evaluate("(status>=200)", "status" => "200")
    assert_equal true, LdapFilter.evaluate("(status>=200)", "status" => "404")
    assert_equal false, LdapFilter.evaluate("(status>=200)", "status" => "199")
    assert_equal true, LdapFilter.evaluate("(status<=404)", "status" => "404")
    assert_equal true, LdapFilter.evaluate("(status<=404)", "status" => "200")
    assert_equal false, LdapFilter.evaluate("(status<=404)", "status" => "500")
  end

  def test_evaluates_leading_and_embedded_wildcards
    assert_equal true, LdapFilter.evaluate("(host=*.example.com)", "host" => "www.example.com")
    assert_equal false, LdapFilter.evaluate("(host=*.example.com)", "host" => "www.example.org")
    assert_equal true, LdapFilter.evaluate("(host=*example*)", "host" => "www.example.com")
    assert_equal false, LdapFilter.evaluate("(host=*example*)", "host" => "www.sample.com")
    assert_equal true, LdapFilter.evaluate("(value=a**b)", "value" => "a--b")
    assert_equal true, LdapFilter.evaluate("(value=a**b)", "value" => "ab")
  end

  def test_wildcard_escapes_literal_regex_metacharacters
    assert_equal true, LdapFilter.evaluate("(value=a.b*)", "value" => "a.b-value")
    assert_equal false, LdapFilter.evaluate("(value=a.b*)", "value" => "axb-value")
  end
end

class CliTest < Minitest::Test
  def test_runs_ltsv_input_and_emits_phases
    Tempfile.create(["ldf", ".ltsv"]) do |file|
      file.write("host:example.com\tstatus:200\n")
      file.write("host:example.org\tstatus:404\n")
      file.close

      stdout = StringIO.new
      stderr = StringIO.new

      LdapFilter::Cli.run(["--format", "ltsv", "(host=example.com)", file.path], stdout: stdout, stderr: stderr)

      assert_includes stdout.string, '{host: "example.com", status: "200"}'
      assert_includes stderr.string, "phase=boot"
      assert_includes stderr.string, "phase=ready"
      assert_includes stderr.string, "phase=done"
    end
  end

  def test_runs_csv_input_and_emits_matching_row
    Tempfile.create(["ldf", ".csv"]) do |file|
      file.write("host,status\n")
      file.write("example.com,200\n")
      file.write("example.org,404\n")
      file.close

      stdout = StringIO.new
      stderr = StringIO.new

      LdapFilter::Cli.run(["--format", "csv", "(host=example.com)", file.path], stdout: stdout, stderr: stderr)

      assert_includes stdout.string, '{host: "example.com", status: "200"}'
      assert_includes stderr.string, "phase=boot"
      assert_includes stderr.string, "phase=ready"
      assert_includes stderr.string, "phase=done"
    end
  end

  def test_csv_handles_quoted_commas_quotes_and_newlines
    Tempfile.create(["ldf", ".csv"]) do |file|
      file.write("host,message\n")
      file.write("example.com,\"hello, \"\"world\"\"\nline\"\n")
      file.close

      stdout = StringIO.new
      stderr = StringIO.new

      LdapFilter::Cli.run(["--format", "csv", "(host=example.com)", file.path], stdout: stdout, stderr: stderr)

      assert_includes stdout.string, %q{message: "hello, \"world\"\nline"}
    end
  end

  def test_csv_removes_utf8_bom_from_the_first_header
    Tempfile.create(["ldf", ".csv"]) do |file|
      file.write("\uFEFFhost,status\nexample.com,200\n")
      file.close

      stdout = StringIO.new
      stderr = StringIO.new

      LdapFilter::Cli.run(["--format", "csv", "(host=example.com)", file.path], stdout: stdout, stderr: stderr)

      assert_includes stdout.string, '{host: "example.com", status: "200"}'
    end
  end

  def test_auto_detects_csv_and_ltsv_content
    Tempfile.create(["ldf", ".log"]) do |file|
      file.write("host:example.com\tstatus:200\n")
      file.close

      assert_equal "ltsv", LdapFilter::Cli.detect_format(file.path)
    end

    Tempfile.create(["ldf", ".log"]) do |file|
      file.write("host,status\nexample.com,200\n")
      file.close

      assert_equal "csv", LdapFilter::Cli.detect_format(file.path)
    end
  end

  def test_xz_input_is_processed
    Tempfile.create(["ldf", ".ltsv"]) do |source|
      source.write("host:example.com\tstatus:200\n")
      source.close

      Tempfile.create(["ldf", ".ltsv.xz"]) do |compressed|
        compressed.close
        assert system("xz", "-c", source.path, out: compressed.path)

        stdout = StringIO.new
        stderr = StringIO.new
        LdapFilter::Cli.run(["--format", "ltsv", "(host=example.com)", compressed.path], stdout: stdout, stderr: stderr)

        assert_includes stdout.string, '{host: "example.com", status: "200"}'
        assert_phase_sequence(stderr.string)
      end
    end
  end

  def test_phase_lines_are_ordered_and_monotonic
    Tempfile.create(["ldf", ".ltsv"]) do |file|
      file.write("host:example.com\n")
      file.close

      stdout = StringIO.new
      stderr = StringIO.new
      LdapFilter::Cli.run(["--format", "ltsv", "(host=example.com)", file.path], stdout: stdout, stderr: stderr)

      assert_phase_sequence(stderr.string)
    end
  end

  def test_gem_executable_accepts_option_form
    Tempfile.create(["ldf", ".ltsv"]) do |file|
      file.write("host:example.com\n")
      file.close

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby,
        "-I", File.expand_path("../lib", __dir__),
        File.expand_path("../bin/ldap_filter", __dir__),
        "--format", "ltsv",
        "--filter", "(host=example.com)",
        "--input", file.path
      )

      assert status.success?
      assert_includes stdout, '{host: "example.com"}'
      assert_phase_sequence(stderr)
    end
  end

  def test_gem_can_be_required_from_a_clean_ruby_process
    lib_path = File.expand_path("../lib", __dir__)
    code = 'require "ldap_filter"; abort unless LdapFilter.evaluate("(host=example.com)", "host" => "example.com")'
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib_path, "-e", code)

    assert status.success?, stderr
  end

  private

  def assert_phase_sequence(stderr)
    lines = stderr.each_line.filter_map do |line|
      match = /\Aphase=(\w+) .*elapsed_ns=(\d+)/.match(line)
      [match[1], match[2].to_i] if match
    end

    assert_equal %w[boot ready done], lines.map(&:first)
    assert lines.each_cons(2).all? { |(_, before), (_, after)| before <= after }
  end
end

class LtsvTest < Minitest::Test
  def test_parses_escaped_values_and_empty_values
    attrs = LdapFilter::Ltsv.parse_line(
      "path:line\\t1\tmessage:hello\\nworld\tquoted:backslash\\\\end\tempty:"
    )

    assert_equal "line\t1", attrs["path"]
    assert_equal "hello\nworld", attrs["message"]
    assert_equal "backslash\\end", attrs["quoted"]
    assert_nil attrs["empty"]
  end

  def test_preserves_colons_and_ignores_malformed_fields
    attrs = LdapFilter::Ltsv.parse_line("url:https://example.com/a:b\tbroken\t:value")

    assert_equal "https://example.com/a:b", attrs["url"]
    refute_includes attrs, "broken"
    refute_includes attrs, ""
  end

  def test_parse_removes_one_record_separator
    assert_equal({ "host" => "example.com" }, LdapFilter::Ltsv.parse("host:example.com\n"))
  end
end
