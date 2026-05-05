using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.RegularExpressions;

[assembly: InternalsVisibleTo("LdapFilter.Tests")]

namespace LdapFilter;

abstract record FilterNode;

sealed record ItemNode(string Attr, string Op, string Value, Regex? Regex) : FilterNode;
sealed record AndNode(IReadOnlyList<FilterNode> Nodes) : FilterNode;
sealed record OrNode(IReadOnlyList<FilterNode> Nodes) : FilterNode;
sealed record NotNode(FilterNode Node) : FilterNode;

sealed class Program
{
    internal static readonly Regex ItemParser = new(@"^([^~=><]+)(~=|>=|<=|=)(.+)$", RegexOptions.Compiled);

    public static async Task<int> Main(string[] args)
    {
        var started = Stopwatch.GetTimestamp();
        var options = ParseArgs(args);

        if (options.Help)
        {
            Console.Out.WriteLine("Usage: ldap_filter [options] FILTER INPUT");
            return 0;
        }

        if (string.IsNullOrWhiteSpace(options.Filter) || string.IsNullOrWhiteSpace(options.Input))
        {
            throw new ArgumentException("filter and input path are required");
        }

        Console.Error.WriteLine(PhaseLine("boot", started));

        var format = options.Format == FormatKind.Auto ? DetectFormat(options.Input) : options.Format;

        Console.Error.WriteLine(PhaseLine("ready", started));

        var ast = Parser.ParseFilter(options.Filter);
        await ProcessInputAsync(options.Input, format, ast);

        Console.Error.WriteLine(PhaseLine("done", started));
        return 0;
    }

    private static async Task ProcessInputAsync(string inputPath, FormatKind format, FilterNode ast)
    {
        await foreach (var attrs in ReadRowsAsync(inputPath, format))
        {
            if (Evaluator.Evaluate(ast, attrs))
            {
                Console.Out.WriteLine(InspectAttrs(attrs));
            }
        }
    }

    private static async IAsyncEnumerable<OrderedAttrs> ReadRowsAsync(string inputPath, FormatKind format)
    {
        await using var input = InputHelper.Open(inputPath);

        if (format == FormatKind.Csv)
        {
            string? headersLine = await input.Reader.ReadLineAsync();
            if (headersLine is null)
            {
                yield break;
            }

            var headers = CsvHelper.ParseHeader(headersLine);
            string? line;
            while ((line = await input.Reader.ReadLineAsync()) is not null)
            {
                if (line.Length == 0)
                {
                    continue;
                }

                yield return CsvHelper.RowToAttrs(headers, CsvHelper.ParseLine(line));
            }

            yield break;
        }

        while (await input.Reader.ReadLineAsync() is { } line)
        {
            yield return LtsvHelper.ParseLine(line);
        }
    }

    private static string InspectAttrs(OrderedAttrs attrs)
    {
        var parts = new List<string>(attrs.Count);
        foreach (var (key, value) in attrs.Items)
        {
            parts.Add($"{FormatKey(key)}{FormatValue(value)}");
        }

        return "{" + string.Join(", ", parts) + "}";
    }

    private static string FormatKey(string key)
    {
        return Regex.IsMatch(key, @"^[A-Za-z_][A-Za-z0-9_]*$")
            ? $"{key}: "
            : $"\"{EscapeRubyString(key)}\" => ";
    }

    private static string FormatValue(string? value)
    {
        return value is null ? "nil" : $"\"{EscapeRubyString(value)}\"";
    }

    private static string EscapeRubyString(string text)
    {
        return text
            .Replace("\\", "\\\\")
            .Replace("\"", "\\\"");
    }

    private static string PhaseLine(string phase, long startTimestamp)
    {
        var elapsedNs = ElapsedNanoseconds(startTimestamp);
        return $"phase={phase} t={elapsedNs} elapsed_ns={elapsedNs}";
    }

    private static long ElapsedNanoseconds(long startTimestamp)
    {
        var delta = Stopwatch.GetTimestamp() - startTimestamp;
        return (long)(delta * 1_000_000_000.0 / Stopwatch.Frequency);
    }

    private static FormatKind DetectFormat(string inputPath)
    {
        if (inputPath.EndsWith(".csv", StringComparison.OrdinalIgnoreCase) ||
            inputPath.EndsWith(".csv.xz", StringComparison.OrdinalIgnoreCase))
        {
            return FormatKind.Csv;
        }

        if (inputPath.EndsWith(".ltsv", StringComparison.OrdinalIgnoreCase) ||
            inputPath.EndsWith(".ltsv.xz", StringComparison.OrdinalIgnoreCase))
        {
            return FormatKind.Ltsv;
        }

        return FormatKind.Ltsv;
    }

    private static CliOptions ParseArgs(string[] args)
    {
        var options = new CliOptions { Format = FormatKind.Auto };
        var positional = new List<string>();

        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            switch (arg)
            {
                case "--filter":
                    options.Filter = NextArg(args, ref i, "--filter");
                    break;
                case "--input":
                    options.Input = NextArg(args, ref i, "--input");
                    break;
                case "--format":
                    options.Format = ParseFormat(NextArg(args, ref i, "--format"));
                    break;
                case "--jit":
                case "--no-jit":
                case "--yjit":
                case "--no-yjit":
                case "--yjit-stats":
                    break;
                case "--help":
                    options.Help = true;
                    break;
                default:
                    if (arg.StartsWith("--", StringComparison.Ordinal))
                    {
                        throw new ArgumentException($"unknown option: {arg}");
                    }
                    positional.Add(arg);
                    break;
            }
        }

        if (string.IsNullOrWhiteSpace(options.Filter) && positional.Count > 0)
        {
            options.Filter = positional[0];
        }

        if (string.IsNullOrWhiteSpace(options.Input) && positional.Count > 1)
        {
            options.Input = positional[1];
        }

        return options;
    }

    private static string NextArg(string[] args, ref int i, string option)
    {
        var nextIndex = i + 1;
        if (nextIndex >= args.Length)
        {
            throw new ArgumentException($"missing value for {option}");
        }

        i = nextIndex;
        return args[nextIndex];
    }

    private static FormatKind ParseFormat(string value)
    {
        return value switch
        {
            "auto" => FormatKind.Auto,
            "csv" => FormatKind.Csv,
            "ltsv" => FormatKind.Ltsv,
            _ => throw new ArgumentException($"unsupported format: {value}")
        };
    }

    private sealed class CliOptions
    {
        public string? Filter { get; set; }
        public string? Input { get; set; }
        public FormatKind Format { get; set; }
        public bool Help { get; set; }
    }

    private enum FormatKind
    {
        Auto,
        Csv,
        Ltsv
    }
}

static class Parser
{
    public static FilterNode ParseFilter(string expr)
    {
        if (string.IsNullOrEmpty(expr))
        {
            throw new ArgumentException("empty filter");
        }

        if (expr[0] == '(')
        {
            var parts = SplitTopLevel(expr);
            return ParseFilter(parts[0]);
        }

        return expr[0] switch
        {
            '&' => new AndNode(SplitTopLevel(expr[1..]).ConvertAll(ParseFilter)),
            '|' => new OrNode(SplitTopLevel(expr[1..]).ConvertAll(ParseFilter)),
            '!' => ParseNot(expr[1..]),
            _ => ParseItem(expr)
        };
    }

    private static FilterNode ParseNot(string expr)
    {
        var parts = SplitTopLevel(expr);
        if (parts.Count != 1)
        {
            throw new ArgumentException("not operator has more than one filter");
        }

        return new NotNode(ParseFilter(parts[0]));
    }

    private static FilterNode ParseItem(string expr)
    {
        var match = Program.ItemParser.Match(expr);
        if (!match.Success)
        {
            throw new ArgumentException("error in item syntax");
        }

        var attr = match.Groups[1].Value;
        var op = match.Groups[2].Value;
        var rawValue = match.Groups[3].Value;

        if (rawValue == "*")
        {
            return new ItemNode(attr, op, rawValue, null);
        }

        var value = UnescapeHex(rawValue);
        Regex? regex = null;
        if (value.Contains('*'))
        {
            var pattern = Regex.Escape(value).Replace(@"\*", ".*");
            regex = new Regex(pattern, RegexOptions.CultureInvariant);
        }

        return new ItemNode(attr, op, value, regex);
    }

    private static string UnescapeHex(string text)
    {
        return Regex.Replace(text, @"\\([0-9a-fA-F]{2})", match =>
        {
            var hex = match.Groups[1].Value;
            var code = int.Parse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            return ((char)code).ToString();
        });
    }

    private static List<string> SplitTopLevel(string expr)
    {
        var parts = new List<string>();
        var depth = 0;
        var start = 0;
        var sawParen = false;

        for (var i = 0; i < expr.Length; i++)
        {
            var ch = expr[i];
            if (ch == '(')
            {
                if (depth == 0)
                {
                    start = i + 1;
                    sawParen = true;
                }
                depth++;
            }
            else if (ch == ')')
            {
                depth--;
                if (depth < 0)
                {
                    throw new ArgumentException("parenthesis mismatch");
                }

                if (depth == 0)
                {
                    parts.Add(expr[start..i]);
                }
            }
        }

        if (depth != 0)
        {
            throw new ArgumentException("parenthesis mismatch");
        }

        return parts.Count > 0 || sawParen ? parts : new List<string> { expr };
    }
}

static class Evaluator
{
    public static bool Evaluate(FilterNode node, OrderedAttrs attrs)
    {
        return node switch
        {
            AndNode andNode => andNode.Nodes.All(child => Evaluate(child, attrs)),
            OrNode orNode => orNode.Nodes.Any(child => Evaluate(child, attrs)),
            NotNode notNode => !Evaluate(notNode.Node, attrs),
            ItemNode itemNode => EvaluateItem(itemNode, attrs),
            _ => throw new ArgumentOutOfRangeException(nameof(node))
        };
    }

    private static bool EvaluateItem(ItemNode node, OrderedAttrs attrs)
    {
        var actual = attrs.TryGetValue(node.Attr);

        if (node.Op == "=")
        {
            if (node.Value == "*")
            {
                return attrs.ContainsKey(node.Attr);
            }

            if (node.Regex is not null)
            {
                return actual is not null && node.Regex.IsMatch(actual);
            }

            return actual == node.Value;
        }

        if (node.Op == "~=")
        {
            return actual is not null && Levenshtein(node.Value, actual) < 3;
        }

        if (node.Op == ">=")
        {
            return actual is not null && string.CompareOrdinal(actual, node.Value) >= 0;
        }

        if (node.Op == "<=")
        {
            return actual is not null && string.CompareOrdinal(actual, node.Value) <= 0;
        }

        throw new ArgumentException($"unsupported operator: {node.Op}");
    }

    private static int Levenshtein(string a, string b)
    {
        var prev = new int[b.Length + 1];
        var curr = new int[b.Length + 1];

        for (var j = 0; j <= b.Length; j++)
        {
            prev[j] = j;
        }

        for (var i = 1; i <= a.Length; i++)
        {
            curr[0] = i;
            for (var j = 1; j <= b.Length; j++)
            {
                var cost = a[i - 1] == b[j - 1] ? 0 : 1;
                curr[j] = Math.Min(
                    Math.Min(prev[j] + 1, curr[j - 1] + 1),
                    prev[j - 1] + cost
                );
            }

            for (var j = 0; j <= b.Length; j++)
            {
                prev[j] = curr[j];
            }
        }

        return prev[b.Length];
    }
}

static class LtsvHelper
{
    public static OrderedAttrs ParseLine(string line)
    {
        var attrs = new OrderedAttrs();
        if (string.IsNullOrEmpty(line))
        {
            return attrs;
        }

        foreach (var entry in line.Split('\t'))
        {
            var index = entry.IndexOf(':');
            if (index < 0)
            {
                continue;
            }

            var key = entry[..index];
            var value = UnescapeValue(entry[(index + 1)..]);
            attrs.Add(key, value);
        }

        return attrs;
    }

    private static string? UnescapeValue(string value)
    {
        if (value.Length == 0)
        {
            return null;
        }

        var sb = new StringBuilder(value.Length);
        for (var i = 0; i < value.Length; i++)
        {
            var ch = value[i];
            if (ch == '\\' && i + 1 < value.Length)
            {
                switch (value[++i])
                {
                    case 'r':
                        sb.Append('\r');
                        break;
                    case 'n':
                        sb.Append('\n');
                        break;
                    case 't':
                        sb.Append('\t');
                        break;
                    case '\\':
                        sb.Append('\\');
                        break;
                    default:
                        sb.Append('\\');
                        sb.Append(value[i]);
                        break;
                }
                continue;
            }

            sb.Append(ch);
        }

        return sb.ToString();
    }
}

static class CsvHelper
{
    public static List<string> ParseHeader(string line)
    {
        if (line.StartsWith('\uFEFF'))
        {
            line = line[1..];
        }

        return ParseLine(line);
    }

    public static List<string> ParseLine(string line)
    {
        var cells = new List<string>();
        var cell = new StringBuilder();
        var quoted = false;

        for (var i = 0; i < line.Length; i++)
        {
            var ch = line[i];
            if (quoted)
            {
                if (ch == '"')
                {
                    if (i + 1 < line.Length && line[i + 1] == '"')
                    {
                        cell.Append('"');
                        i++;
                    }
                    else
                    {
                        quoted = false;
                    }
                }
                else
                {
                    cell.Append(ch);
                }
            }
            else if (ch == ',')
            {
                cells.Add(cell.ToString());
                cell.Clear();
            }
            else if (ch == '"')
            {
                quoted = true;
            }
            else
            {
                cell.Append(ch);
            }
        }

        cells.Add(cell.ToString());
        return cells;
    }

    public static OrderedAttrs RowToAttrs(IReadOnlyList<string> headers, IReadOnlyList<string> row)
    {
        var attrs = new OrderedAttrs();
        for (var i = 0; i < headers.Count; i++)
        {
            attrs.Add(headers[i], i < row.Count ? row[i] : "");
        }

        return attrs;
    }
}

static class InputHelper
{
    public static InputHandle Open(string inputPath)
    {
        if (inputPath.EndsWith(".xz", StringComparison.OrdinalIgnoreCase))
        {
            return OpenXz(inputPath);
        }

        return new InputHandle(File.OpenText(inputPath), null, null);
    }

    private static InputHandle OpenXz(string inputPath)
    {
        var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = "xz",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            }
        };

        process.StartInfo.ArgumentList.Add("-dc");
        process.StartInfo.ArgumentList.Add(inputPath);

        if (!process.Start())
        {
            throw new InvalidOperationException($"failed to start xz for {inputPath}");
        }

        var stderrTask = process.StandardError.ReadToEndAsync();
        return new InputHandle(process.StandardOutput, process, stderrTask);
    }
}

sealed class InputHandle : IAsyncDisposable
{
    public InputHandle(StreamReader reader, Process? process, Task<string>? stderrTask)
    {
        Reader = reader;
        Process = process;
        StderrTask = stderrTask;
    }

    public StreamReader Reader { get; }
    private Process? Process { get; }
    private Task<string>? StderrTask { get; }

    public async ValueTask DisposeAsync()
    {
        Reader.Dispose();

        if (Process is null)
        {
            return;
        }

        Process.WaitForExit();
        if (StderrTask is not null)
        {
            var stderr = await StderrTask;
            if (Process.ExitCode != 0)
            {
                throw new ArgumentException($"xz failed: {stderr.Trim()}");
            }
        }

        Process.Dispose();
    }
}

sealed class OrderedAttrs
{
    private readonly Dictionary<string, string?> values = new(StringComparer.Ordinal);

    public int Count => values.Count;
    public IEnumerable<KeyValuePair<string, string?>> Items => values;

    public void Add(string key, string? value)
    {
        values[key] = value;
    }

    public bool ContainsKey(string key)
    {
        return values.ContainsKey(key);
    }

    public string? TryGetValue(string key)
    {
        return values.TryGetValue(key, out var value) ? value : null;
    }
}
