require_relative "test_helper"

class LdapFilterParserTest < Minitest::Test
  def test_parses_wildcard_filter
    parser = LdapFilterParser.new
    parser.parse("(host=www.*)")

    item = parser.result
    assert_kind_of LdapFilterItem, item
    assert_equal "=", item.filtertype
    assert_equal "host", item.attr
    assert_equal "www.*", item.value
    assert_kind_of Regexp, item.regex
  end

  def test_parses_presence_filter
    parser = LdapFilterParser.new
    parser.parse("(host=*)")

    item = parser.result
    assert_kind_of LdapFilterItem, item
    assert_equal "*", item.value
    assert_nil item.regex
  end
end

class LdapFilterEvaluatorTest < Minitest::Test
  def test_evaluates_logical_expression
    evaluator = LdapFilterEvaluator.new("(&(host=www.*)(status=200))", keytype: :symbol)

    attrs = {
      host: "www.example.com",
      status: "200"
    }

    assert_equal true, evaluator.evaluate(attrs)
  end

  def test_evaluates_presence_filter
    evaluator = LdapFilterEvaluator.new("(host=*)", keytype: :symbol)

    assert_equal true, evaluator.evaluate(host: "example")
    assert_equal false, evaluator.evaluate({})
  end
end

class LdapFilterCommandTest < Minitest::Test
  def test_runs_ltsv_input_and_emits_phases
    Tempfile.create(["ldf", ".ltsv"]) do |file|
      file.write("host:example.com\tstatus:200\n")
      file.write("host:example.org\tstatus:404\n")
      file.close

      stdout = StringIO.new
      stderr = StringIO.new

      LdapFilterCommand.run(["--format", "ltsv", "(host=example.com)", file.path], stdout: stdout, stderr: stderr)

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

      LdapFilterCommand.run(["--format", "csv", "(host=example.com)", file.path], stdout: stdout, stderr: stderr)

      assert_includes stdout.string, '{host: "example.com", status: "200"}'
      assert_includes stderr.string, "phase=boot"
      assert_includes stderr.string, "phase=ready"
      assert_includes stderr.string, "phase=done"
    end
  end
end
