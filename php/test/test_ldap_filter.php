<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/ldap_filter.php';

function assertSameValue(mixed $expected, mixed $actual, string $message = ''): void
{
    if ($expected !== $actual) {
        throw new RuntimeException($message . "\nexpected: " . var_export($expected, true) . "\nactual:   " . var_export($actual, true));
    }
}

function assertTrueValue(bool $actual, string $message = ''): void
{
    assertSameValue(true, $actual, $message);
}

function runCli(array $args): array
{
    $cmd = escapeshellarg(PHP_BINARY) . ' ' . escapeshellarg(dirname(__DIR__) . '/ldap_filter.php');
    foreach ($args as $arg) {
        $cmd .= ' ' . escapeshellarg((string) $arg);
    }

    $descriptors = [
        0 => ['pipe', 'r'],
        1 => ['pipe', 'w'],
        2 => ['pipe', 'w'],
    ];
    $pipes = [];
    $process = proc_open($cmd, $descriptors, $pipes);
    if (!is_resource($process)) {
        throw new RuntimeException('failed to start PHP CLI');
    }

    fclose($pipes[0]);
    $stdout = stream_get_contents($pipes[1]);
    fclose($pipes[1]);
    $stderr = stream_get_contents($pipes[2]);
    fclose($pipes[2]);
    $code = proc_close($process);

    return [$code, $stdout, $stderr];
}

function createTempFile(string $suffix, string $content): string
{
    $path = tempnam(sys_get_temp_dir(), 'ldf-');
    if ($path === false) {
        throw new RuntimeException('failed to create temp file');
    }
    $target = $path . $suffix;
    rename($path, $target);
    file_put_contents($target, $content);
    return $target;
}

function maybeCreateXz(string $path): string
{
    $result = trim((string) shell_exec('command -v xz 2>/dev/null'));
    if ($result === '') {
        return '';
    }

    $xzPath = $path . '.xz';
    $cmd = 'xz -c ' . escapeshellarg($path) . ' > ' . escapeshellarg($xzPath);
    exec($cmd, $output, $code);
    if ($code !== 0) {
        return '';
    }
    return $xzPath;
}

function testInspectAttrs(): void
{
    $attrs = new OrderedAttrs();
    $attrs->add('host', 'www.example.com');
    $attrs->add('http/2', 'true');
    assertSameValue('{host: "www.example.com", "http/2" => "true"}', inspectAttrs($attrs), 'inspectAttrs mismatch');
}

function testParserAndEvaluator(): void
{
    $attrs = new OrderedAttrs();
    $attrs->add('host', 'www.example.com');
    $attrs->add('status', '200');

    assertTrueValue(parseFilter('(host=*)')->evaluate($attrs), 'presence filter failed');
    assertTrueValue(parseFilter('(host=www.example.com)')->evaluate($attrs), 'exact filter failed');
    assertTrueValue(parseFilter('(&(host=www.example.com)(status>=200))')->evaluate($attrs), 'compound filter failed');
    assertTrueValue(!parseFilter('(!(host=www.example.com))')->evaluate($attrs), 'not filter failed');
}

function testLtsvParsing(): void
{
    $attrs = parseLtsvLine("path:line\\t1\tmessage:hello\\nworld\tquoted:backslash\\\\end");
    assertSameValue('{path: "line\t1", message: "hello\nworld", quoted: "backslash\\\\end"}', inspectAttrs($attrs), 'LTSV parse mismatch');
}

function testCliCsvAndLtsv(): void
{
    $csv = createTempFile('.csv', "host,status\nwww.example.com,200\nother.example.com,404\n");
    $ltsv = createTempFile('.ltsv', "host:www.example.com\tstatus:200\nhost:other.example.com\tstatus:404\n");

    [$codeCsv, $stdoutCsv, $stderrCsv] = runCli(['--filter', '(host=www.example.com)', '--input', $csv, '--format', 'csv']);
    assertSameValue(0, $codeCsv, 'CSV CLI exit code');
    assertSameValue("{host: \"www.example.com\", status: \"200\"}\n", $stdoutCsv, 'CSV stdout');
    assertTrueValue(str_contains($stderrCsv, 'phase=boot'), 'CSV stderr boot');
    assertTrueValue(str_contains($stderrCsv, 'phase=ready'), 'CSV stderr ready');
    assertTrueValue(str_contains($stderrCsv, 'phase=done'), 'CSV stderr done');

    [$codeLtsv, $stdoutLtsv, $stderrLtsv] = runCli(['--filter', '(host=www.example.com)', '--input', $ltsv, '--format', 'ltsv']);
    assertSameValue(0, $codeLtsv, 'LTSV CLI exit code');
    assertSameValue("{host: \"www.example.com\", status: \"200\"}\n", $stdoutLtsv, 'LTSV stdout');
    assertTrueValue(str_contains($stderrLtsv, 'phase=boot'), 'LTSV stderr boot');
    assertTrueValue(str_contains($stderrLtsv, 'phase=ready'), 'LTSV stderr ready');
    assertTrueValue(str_contains($stderrLtsv, 'phase=done'), 'LTSV stderr done');

    $xzCsv = maybeCreateXz($csv);
    if ($xzCsv !== '') {
        [$codeXz, $stdoutXz, $stderrXz] = runCli(['--filter', '(host=www.example.com)', '--input', $xzCsv]);
        assertSameValue(0, $codeXz, 'XZ CSV CLI exit code');
        assertSameValue("{host: \"www.example.com\", status: \"200\"}\n", $stdoutXz, 'XZ CSV stdout');
        assertTrueValue(str_contains($stderrXz, 'phase=done'), 'XZ CSV stderr done');
    }
}

testInspectAttrs();
testParserAndEvaluator();
testLtsvParsing();
testCliCsvAndLtsv();

fwrite(STDOUT, "OK\n");
