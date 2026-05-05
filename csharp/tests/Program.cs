using LdapFilter;

namespace LdapFilter.Tests;

internal static class Program
{
    public static async Task<int> Main()
    {
        var tests = new (string Name, Func<Task> Body)[]
        {
            ("parser_and_evaluator", TestParserAndEvaluatorAsync),
            ("csv_and_ltsv_helpers", TestCsvAndLtsvHelpersAsync),
            ("cli_output_and_phases", TestCliOutputAndPhasesAsync),
        };

        Console.WriteLine($"1..{tests.Length}");

        var failed = 0;
        for (var i = 0; i < tests.Length; i++)
        {
            var (name, body) = tests[i];
            try
            {
                await body();
                Console.WriteLine($"ok {i + 1} - {name}");
            }
            catch (Exception ex)
            {
                failed++;
                Console.Error.WriteLine($"not ok {i + 1} - {name}: {ex.Message}");
            }
        }

        return failed == 0 ? 0 : 1;
    }

    private static Task TestParserAndEvaluatorAsync()
    {
        var attrs = new OrderedAttrs();
        attrs.Add("host", "example.com");
        attrs.Add("pass", "true");
        attrs.Add("cn", "foo bar");
        attrs.Add("age", "10");

        AssertTrue(Evaluator.Evaluate(Parser.ParseFilter("(host=*)"), attrs), "presence filter");
        AssertTrue(Evaluator.Evaluate(Parser.ParseFilter("(host=example.com)"), attrs), "exact match");
        AssertTrue(Evaluator.Evaluate(Parser.ParseFilter("(host=exam*ple.com)"), attrs), "wildcard match");
        AssertTrue(Evaluator.Evaluate(Parser.ParseFilter("(host~=exampel.com)"), attrs), "approx match");
        AssertTrue(Evaluator.Evaluate(Parser.ParseFilter("(age>=10)"), attrs), "greater or equal");
        AssertTrue(Evaluator.Evaluate(Parser.ParseFilter("(age<=10)"), attrs), "less or equal");
        AssertTrue(Evaluator.Evaluate(Parser.ParseFilter("(cn=foo\\20bar)"), attrs), "hex escape");
        AssertFalse(Evaluator.Evaluate(Parser.ParseFilter("(!(pass=true))"), attrs), "not operator");
        AssertTrue(Evaluator.Evaluate(Parser.ParseFilter("(&(host=example.com)(pass=true))"), attrs), "and operator");
        AssertTrue(Evaluator.Evaluate(Parser.ParseFilter("(|(host=nope)(pass=true))"), attrs), "or operator");

        return Task.CompletedTask;
    }

    private static Task TestCsvAndLtsvHelpersAsync()
    {
        var headers = CsvHelper.ParseHeader("\uFEFFhost,pass,comment");
        var row = CsvHelper.ParseLine("\"example,com\",\"tr\"\"ue\",tail");
        var attrs = CsvHelper.RowToAttrs(headers, row);

        AssertEqual("example,com", attrs.TryGetValue("host"), "csv host");
        AssertEqual("tr\"ue", attrs.TryGetValue("pass"), "csv pass");
        AssertEqual("tail", attrs.TryGetValue("comment"), "csv comment");

        var ltsv = LtsvHelper.ParseLine("host:example\\tcom\tpass:true\tcomment:line\\nnext");
        AssertEqual("example\tcom", ltsv.TryGetValue("host"), "ltsv host");
        AssertEqual("true", ltsv.TryGetValue("pass"), "ltsv pass");
        AssertEqual("line\nnext", ltsv.TryGetValue("comment"), "ltsv comment");

        return Task.CompletedTask;
    }

    private static async Task TestCliOutputAndPhasesAsync()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ldf-csharp-tests-" + Path.GetRandomFileName());
        Directory.CreateDirectory(dir);

        try
        {
            var csvPath = Path.Combine(dir, "sample.csv");
            await File.WriteAllTextAsync(
                csvPath,
                "host,pass\nexample.com,true\nother,false\n"
            );

            var ltsvPath = Path.Combine(dir, "sample.ltsv");
            await File.WriteAllTextAsync(
                ltsvPath,
                "host:example.com\tpass:true\nhost:other\tpass:false\n"
            );

            var csvRun = await RunCliAsync("--format", "auto", "(host=example.com)", csvPath);
            AssertEqual(0, csvRun.ExitCode, "csv exit");
            AssertEqual("{host: \"example.com\", pass: \"true\"}", csvRun.Stdout.Trim(), "csv stdout");
            AssertPhaseLines(csvRun.Stderr, "boot", "ready", "done");

            var ltsvRun = await RunCliAsync("(host=example.com)", ltsvPath);
            AssertEqual(0, ltsvRun.ExitCode, "ltsv exit");
            AssertEqual("{host: \"example.com\", pass: \"true\"}", ltsvRun.Stdout.Trim(), "ltsv stdout");
            AssertPhaseLines(ltsvRun.Stderr, "boot", "ready", "done");
        }
        finally
        {
            try
            {
                Directory.Delete(dir, recursive: true);
            }
            catch
            {
                // テスト用一時ディレクトリなので、削除失敗は本体の判定に影響させない。
            }
        }
    }

    private static async Task<(string Stdout, string Stderr, int ExitCode)> RunCliAsync(params string[] args)
    {
        var originalOut = Console.Out;
        var originalErr = Console.Error;
        var stdout = new StringWriter();
        var stderr = new StringWriter();

        try
        {
            Console.SetOut(stdout);
            Console.SetError(stderr);
            var exitCode = await global::LdapFilter.Program.Main(args);
            return (stdout.ToString(), stderr.ToString(), exitCode);
        }
        finally
        {
            Console.SetOut(originalOut);
            Console.SetError(originalErr);
        }
    }

    private static void AssertPhaseLines(string stderr, params string[] phases)
    {
        var lines = stderr
            .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries)
            .ToArray();

        AssertEqual(phases.Length, lines.Length, "stderr phase line count");
        for (var i = 0; i < phases.Length; i++)
        {
            AssertTrue(lines[i].StartsWith($"phase={phases[i]} ", StringComparison.Ordinal), $"phase {phases[i]}");
            AssertTrue(lines[i].Contains("elapsed_ns="), $"elapsed_ns for {phases[i]}");
            AssertTrue(lines[i].Contains(" t="), $"t for {phases[i]}");
        }
    }

    private static void AssertTrue(bool condition, string label)
    {
        if (!condition)
        {
            throw new InvalidOperationException($"assertion failed: {label}");
        }
    }

    private static void AssertFalse(bool condition, string label)
    {
        AssertTrue(!condition, label);
    }

    private static void AssertEqual<T>(T expected, T actual, string label)
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"assertion failed: {label}: expected={expected} actual={actual}");
        }
    }
}
