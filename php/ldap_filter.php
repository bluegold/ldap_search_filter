<?php
declare(strict_types=1);

final class LdapFilterError extends RuntimeException
{
}

abstract class FilterExpr
{
    abstract public function evaluate(OrderedAttrs $attrs): bool;
}

final class FilterAnd extends FilterExpr
{
    /**
     * @param FilterExpr[] $children
     */
    public function __construct(private array $children)
    {
    }

    public function evaluate(OrderedAttrs $attrs): bool
    {
        foreach ($this->children as $child) {
            if (!$child->evaluate($attrs)) {
                return false;
            }
        }

        return true;
    }
}

final class FilterOr extends FilterExpr
{
    /**
     * @param FilterExpr[] $children
     */
    public function __construct(private array $children)
    {
    }

    public function evaluate(OrderedAttrs $attrs): bool
    {
        foreach ($this->children as $child) {
            if ($child->evaluate($attrs)) {
                return true;
            }
        }

        return false;
    }
}

final class FilterNot extends FilterExpr
{
    public function __construct(private FilterExpr $child)
    {
    }

    public function evaluate(OrderedAttrs $attrs): bool
    {
        return !$this->child->evaluate($attrs);
    }
}

final class ItemMatcher
{
    /**
     * @param string[] $parts
     */
    public function __construct(
        public string $kind,
        public array $parts = [],
        public bool $leadingStar = false,
        public bool $trailingStar = false,
    ) {
    }
}

final class FilterItem extends FilterExpr
{
    public function __construct(
        private string $attr,
        private string $op,
        private string $value,
        private ItemMatcher $matcher,
    ) {
    }

    public function evaluate(OrderedAttrs $attrs): bool
    {
        $actual = $attrs->get($this->attr);

        if ($this->op === '=') {
            if ($this->matcher->kind === 'presence') {
                return $attrs->contains($this->attr);
            }

            if ($actual === null) {
                return false;
            }

            if ($this->matcher->kind === 'wildcard') {
                return wildcardMatches(
                    $this->matcher->parts,
                    $this->matcher->leadingStar,
                    $this->matcher->trailingStar,
                    $actual,
                );
            }

            return $actual === $this->value;
        }

        if ($actual === null) {
            return false;
        }

        if ($this->op === '~=') {
            return levenshtein($actual, $this->value) <= 2;
        }

        if ($this->op === '>=') {
            return $actual >= $this->value;
        }

        if ($this->op === '<=') {
            return $actual <= $this->value;
        }

        throw new LdapFilterError("unsupported operator: {$this->op}");
    }
}

final class OrderedAttrs
{
    /**
     * @var array<int, array{0: string, 1: ?string}>
     */
    private array $items = [];

    public function add(string $key, ?string $value): void
    {
        $this->items[] = [$key, $value];
    }

    public function contains(string $key): bool
    {
        foreach ($this->items as [$candidate, $_]) {
            if ($candidate === $key) {
                return true;
            }
        }

        return false;
    }

    public function get(string $key): ?string
    {
        foreach ($this->items as [$candidate, $value]) {
            if ($candidate === $key) {
                return $value;
            }
        }

        return null;
    }

    /**
     * @return array<int, array{0: string, 1: ?string}>
     */
    public function items(): array
    {
        return $this->items;
    }
}

final class FilterParser
{
    public function __construct(
        private string $text,
    ) {
    }

    public function parse(): FilterExpr
    {
        $expr = $this->parseFilter();
        if ($this->pos !== strlen($this->text)) {
            throw $this->error('unexpected trailing characters');
        }

        return $expr;
    }

    private int $pos = 0;

    private function parseFilter(): FilterExpr
    {
        $this->expect('(');
        $current = $this->peek();
        if ($current === null) {
            throw $this->error('parenthesis mismatch');
        }

        if ($current === '&') {
            $this->pos++;
            $children = $this->parseSubfilters();
            if ($children === []) {
                throw $this->error('and operator requires filters');
            }
            $this->expect(')');
            return new FilterAnd($children);
        }

        if ($current === '|') {
            $this->pos++;
            $children = $this->parseSubfilters();
            if ($children === []) {
                throw $this->error('or operator requires filters');
            }
            $this->expect(')');
            return new FilterOr($children);
        }

        if ($current === '!') {
            $this->pos++;
            $child = $this->parseFilter();
            if ($this->peek() === '(') {
                throw $this->error('not operator has more than one filter');
            }
            $this->expect(')');
            return new FilterNot($child);
        }

        $item = $this->parseItem();
        $this->expect(')');
        return $item;
    }

    /**
     * @return FilterExpr[]
     */
    private function parseSubfilters(): array
    {
        $children = [];
        while ($this->peek() === '(') {
            $children[] = $this->parseFilter();
        }
        return $children;
    }

    private function parseItem(): FilterItem
    {
        $start = $this->pos;
        while (true) {
            $current = $this->peek();
            if ($current === null) {
                throw $this->error('parenthesis mismatch');
            }
            if ($current === ')') {
                break;
            }
            $this->pos++;
        }

        $item = substr($this->text, $start, $this->pos - $start);
        if (!preg_match('/\A([^~=><]+)(~=|>=|<=|=)(.+)\z/s', $item, $matches)) {
            throw $this->error('error in item syntax', $start);
        }

        $attr = $matches[1];
        $op = $matches[2];
        $rawValue = $matches[3];
        [$value, $matcher] = parseItemValue($rawValue, $start);
        return new FilterItem($attr, $op, $value, $matcher);
    }

    private function peek(): ?string
    {
        if ($this->pos >= strlen($this->text)) {
            return null;
        }

        return $this->text[$this->pos];
    }

    private function expect(string $expected): void
    {
        $actual = $this->peek();
        if ($actual !== $expected) {
            if ($actual === null) {
                throw $this->error("expected " . var_export($expected, true) . ', found EOF');
            }
            throw $this->error("expected " . var_export($expected, true) . ', found ' . var_export($actual, true));
        }
        $this->pos++;
    }

    private function error(string $message, ?int $position = null): LdapFilterError
    {
        if ($position === null) {
            $position = $this->pos;
        }
        return new LdapFilterError(sprintf('%s at position %d', $message, $position));
    }
}

function parseFilter(string $text): FilterExpr
{
    return (new FilterParser($text))->parse();
}

/**
 * @return array{0: string, 1: ItemMatcher}
 */
function parseItemValue(string $raw, int $position): array
{
    if ($raw === '*') {
        return ['*', new ItemMatcher('presence')];
    }

    $decoded = '';
    $segments = [];
    $current = '';
    $sawWildcard = false;
    $len = strlen($raw);

    for ($i = 0; $i < $len;) {
        $ch = $raw[$i];
        if ($ch === '\\') {
            if ($i + 2 >= $len) {
                throw new LdapFilterError(sprintf('incomplete escape sequence at position %d', $position));
            }
            $decodedChar = decodeHexEscape($raw[$i + 1], $raw[$i + 2], $position);
            $decoded .= $decodedChar;
            $current .= $decodedChar;
            $i += 3;
            continue;
        }

        if ($ch === '*') {
            $sawWildcard = true;
            $decoded .= '*';
            $segments[] = $current;
            $current = '';
            $i++;
            continue;
        }

        $decoded .= $ch;
        $current .= $ch;
        $i++;
    }

    if (!$sawWildcard) {
        return [$decoded, new ItemMatcher('exact')];
    }

    $segments[] = $current;
    return [
        $decoded,
        new ItemMatcher(
            'wildcard',
            $segments,
            str_starts_with($raw, '*'),
            str_ends_with($raw, '*'),
        ),
    ];
}

function decodeHexEscape(string $high, string $low, int $position): string
{
    if (!ctype_xdigit($high) || !ctype_xdigit($low)) {
        throw new LdapFilterError(sprintf('invalid escape sequence: \\%s%s at position %d', $high, $low, $position));
    }

    return chr(hexdec($high . $low));
}

/**
 * @param string[] $parts
 */
function wildcardMatches(array $parts, bool $leadingStar, bool $trailingStar, string $actual): bool
{
    $partCount = count($parts);
    if ($partCount === 0) {
        return $actual === '';
    }

    $start = 0;
    $end = $partCount - 1;
    $offset = 0;

    if (!$leadingStar) {
        $first = $parts[0];
        if (!str_starts_with($actual, $first)) {
            return false;
        }
        $offset = strlen($first);
        $start = 1;
    }

    if (!$trailingStar) {
        $last = $parts[$end];
        if ($last !== '') {
            $lastPos = strrpos($actual, $last);
            if ($lastPos === false || $lastPos + strlen($last) !== strlen($actual)) {
                return false;
            }
        }
        $end--;
    }

    for ($i = $start; $i <= $end; $i++) {
        $part = $parts[$i];
        if ($part === '') {
            continue;
        }

        $found = strpos($actual, $part, $offset);
        if ($found === false) {
            return false;
        }

        $offset = $found + strlen($part);
    }

    return true;
}

function inspectAttrs(OrderedAttrs $attrs): string
{
    $parts = [];
    foreach ($attrs->items() as [$key, $value]) {
        $parts[] = formatKey($key) . formatValue($value);
    }
    return '{' . implode(', ', $parts) . '}';
}

function formatKey(string $key): string
{
    if (isRubySymbolName($key)) {
        return $key . ': ';
    }
    return json_encode($key, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES) . ' => ';
}

function formatValue(?string $value): string
{
    if ($value === null) {
        return 'nil';
    }
    return json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
}

function isRubySymbolName(string $key): bool
{
    return (bool) preg_match('/\A[A-Za-z_][A-Za-z0-9_]*\z/', $key);
}

/**
 * @return array{0: string|null, 1: string|null}
 */
function parseArgs(array $argv): array
{
    $options = [
        'filter' => null,
        'input' => null,
        'format' => 'auto',
    ];
    $positionals = [];

    $count = count($argv);
    for ($i = 1; $i < $count; $i++) {
        $arg = $argv[$i];

        if ($arg === '--help' || $arg === '-h') {
            printUsage();
            exit(0);
        }

        if ($arg === '--jit' || $arg === '--no-jit') {
            continue;
        }

        if ($arg === '--filter' || $arg === '--input' || $arg === '--format') {
            if ($i + 1 >= $count) {
                throw new InvalidArgumentException("missing value for {$arg}");
            }
            $value = $argv[++$i];
            if ($arg === '--filter') {
                $options['filter'] = $value;
            } elseif ($arg === '--input') {
                $options['input'] = $value;
            } else {
                $options['format'] = $value;
            }
            continue;
        }

        if (str_starts_with($arg, '--filter=')) {
            $options['filter'] = substr($arg, 9);
            continue;
        }
        if (str_starts_with($arg, '--input=')) {
            $options['input'] = substr($arg, 8);
            continue;
        }
        if (str_starts_with($arg, '--format=')) {
            $options['format'] = substr($arg, 9);
            continue;
        }

        if (str_starts_with($arg, '--')) {
            throw new InvalidArgumentException("unsupported option: {$arg}");
        }

        $positionals[] = $arg;
    }

    if ($options['filter'] === null && isset($positionals[0])) {
        $options['filter'] = $positionals[0];
    }
    if ($options['input'] === null && isset($positionals[1])) {
        $options['input'] = $positionals[1];
    }

    return [$options['filter'], $options['input'], $options['format']];
}

function printUsage(): void
{
    fwrite(STDOUT, "Usage: php ldap_filter.php [options] FILTER INPUT\n");
}

function runWithIo(array $argv): int
{
    [$filter, $inputPath, $format] = parseArgs($argv);
    if ($filter === null || $inputPath === null) {
        throw new InvalidArgumentException('filter and input path are required');
    }

    $startNs = monotonicNs();
    fwrite(STDERR, phaseLine('boot', $startNs, monotonicNs()) . "\n");

    $format = selectFormat($format, $inputPath);
    $expr = parseFilter($filter);

    fwrite(STDERR, phaseLine('ready', $startNs, monotonicNs()) . "\n");

    processInput($inputPath, $format, $expr);

    fwrite(STDERR, phaseLine('done', $startNs, monotonicNs()) . "\n");
    return 0;
}

function selectFormat(string $format, string $inputPath): string
{
    if ($format !== 'auto') {
        return $format;
    }

    return detectFormat($inputPath);
}

function detectFormat(string $inputPath): string
{
    $base = basename($inputPath);
    if (str_ends_with($base, '.csv') || str_ends_with($base, '.csv.xz')) {
        return 'csv';
    }
    if (str_ends_with($base, '.ltsv') || str_ends_with($base, '.ltsv.xz')) {
        return 'ltsv';
    }

    $firstLine = withInputHandle($inputPath, static function ($handle): ?string {
        while (($line = fgets($handle)) !== false) {
            if (trim($line) !== '') {
                return $line;
            }
        }
        return null;
    });

    if ($firstLine !== null && str_contains($firstLine, "\t")) {
        return 'ltsv';
    }

    return 'csv';
}

function processInput(string $inputPath, string $format, FilterExpr $expr): void
{
    if ($format === 'csv') {
        eachCsvAttrs($inputPath, static function (OrderedAttrs $attrs) use ($expr): void {
            if ($expr->evaluate($attrs)) {
                fwrite(STDOUT, inspectAttrs($attrs) . "\n");
            }
        });
        return;
    }

    if ($format === 'ltsv') {
        eachLtsvAttrs($inputPath, static function (OrderedAttrs $attrs) use ($expr): void {
            if ($expr->evaluate($attrs)) {
                fwrite(STDOUT, inspectAttrs($attrs) . "\n");
            }
        });
        return;
    }

    throw new InvalidArgumentException("unsupported format: {$format}");
}

/**
 * @param callable(OrderedAttrs): void $callback
 */
function eachCsvAttrs(string $inputPath, callable $callback): void
{
    withInputHandle($inputPath, static function ($handle) use ($callback): void {
        $headers = fgetcsv($handle);
        if ($headers === false) {
            return;
        }

        if ($headers !== [] && isset($headers[0])) {
            $headers[0] = preg_replace('/^\xEF\xBB\xBF/', '', (string) $headers[0]);
        }

        while (($row = fgetcsv($handle)) !== false) {
            if ($row === [null]) {
                continue;
            }

            $attrs = new OrderedAttrs();
            $headerCount = count($headers);
            for ($i = 0; $i < $headerCount; $i++) {
                $value = $row[$i] ?? '';
                $attrs->add((string) $headers[$i], $value === null ? '' : (string) $value);
            }

            $callback($attrs);
        }
    });
}

/**
 * @param callable(OrderedAttrs): void $callback
 */
function eachLtsvAttrs(string $inputPath, callable $callback): void
{
    withInputHandle($inputPath, static function ($handle) use ($callback): void {
        while (($line = fgets($handle)) !== false) {
            $line = rtrim($line, "\r\n");
            if ($line === '') {
                continue;
            }

            $attrs = parseLtsvLine($line);
            $callback($attrs);
        }
    });
}

function parseLtsvLine(string $line): OrderedAttrs
{
    $attrs = new OrderedAttrs();
    foreach (explode("\t", $line) as $field) {
        if ($field === '') {
            continue;
        }

        $separator = strpos($field, ':');
        if ($separator === false) {
            continue;
        }

        $key = substr($field, 0, $separator);
        $value = substr($field, $separator + 1);
        $attrs->add($key, unescapeLtsvValue($value));
    }

    return $attrs;
}

function unescapeLtsvValue(string $text): string
{
    return str_replace(['\\\\', '\t', '\n', '\r'], ['\\', "\t", "\n", "\r"], $text);
}

/**
 * @template T
 * @param callable(string): T $callback
 * @return T
 */
function withInputHandle(string $inputPath, callable $callback)
{
    if (str_ends_with($inputPath, '.xz')) {
        $cmd = 'xz -dc ' . escapeshellarg($inputPath);
        $descriptors = [
            0 => ['pipe', 'r'],
            1 => ['pipe', 'w'],
            2 => ['pipe', 'w'],
        ];
        $pipes = [];
        $process = proc_open($cmd, $descriptors, $pipes);
        if (!is_resource($process)) {
            throw new RuntimeException("failed to open xz process for {$inputPath}");
        }

        fclose($pipes[0]);
        try {
            return $callback($pipes[1]);
        } finally {
            if (isset($pipes[1]) && is_resource($pipes[1])) {
                fclose($pipes[1]);
            }
            $stderr = '';
            if (isset($pipes[2]) && is_resource($pipes[2])) {
                $stderr = stream_get_contents($pipes[2]) ?: '';
                fclose($pipes[2]);
            }
            $exitCode = proc_close($process);
            if ($exitCode !== 0) {
                throw new RuntimeException(sprintf('xz failed for %s: %s', $inputPath, trim($stderr)));
            }
        }
    }

    $handle = fopen($inputPath, 'rb');
    if ($handle === false) {
        throw new RuntimeException("failed to open {$inputPath}");
    }

    try {
        return $callback($handle);
    } finally {
        fclose($handle);
    }
}

function phaseLine(string $phase, int $startNs, int $nowNs): string
{
    $elapsedNs = $nowNs - $startNs;
    return sprintf('phase=%s t=%d elapsed_ns=%d', $phase, $elapsedNs, $elapsedNs);
}

function monotonicNs(): int
{
    return hrtime(true);
}

function main(array $argv): int
{
    try {
        return runWithIo($argv);
    } catch (Throwable $e) {
        fwrite(STDERR, $e->getMessage() . "\n");
        return 1;
    }
}

if (PHP_SAPI === 'cli' && realpath($argv[0] ?? '') === __FILE__) {
    exit(main($argv));
}
