require_relative "test_helper"

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
end
