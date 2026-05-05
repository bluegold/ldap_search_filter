package main

import (
	"bufio"
	"bytes"
	"encoding/csv"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

type formatKind string

const (
	formatAuto formatKind = "auto"
	formatCSV  formatKind = "csv"
	formatLTSV formatKind = "ltsv"
)

type filterExpr interface {
	match(attrs orderedAttrs) bool
}

type filterItem struct {
	attr     string
	op       string
	value    string
	wildcard *wildcardPattern
}

type filterAnd struct {
	nodes []filterExpr
}

type filterOr struct {
	nodes []filterExpr
}

type filterNot struct {
	node filterExpr
}

type wildcardPattern struct {
	parts        []string
	leadingStar  bool
	trailingStar bool
}

type orderedAttr struct {
	key   string
	value *string
}

type orderedAttrs struct {
	items []orderedAttr
}

type parseError struct {
	message string
}

func (e parseError) Error() string { return e.message }

func newOrderedAttrs() orderedAttrs {
	return orderedAttrs{items: make([]orderedAttr, 0)}
}

func (a *orderedAttrs) add(key string, value *string) {
	a.items = append(a.items, orderedAttr{key: key, value: value})
}

func (a orderedAttrs) get(key string) (*string, bool) {
	for _, item := range a.items {
		if item.key == key {
			return item.value, true
		}
	}
	return nil, false
}

func (a orderedAttrs) len() int { return len(a.items) }

func parseFilter(expr string) (filterExpr, error) {
	node, next, err := parseFilterAt(expr, 0)
	if err != nil {
		return nil, err
	}
	if next != len(expr) {
		return nil, parseError{message: "unexpected trailing input"}
	}
	return node, nil
}

func parseFilterAt(expr string, pos int) (filterExpr, int, error) {
	if pos >= len(expr) || expr[pos] != '(' {
		return nil, pos, parseError{message: "expected '('"}
	}

	depth := 0
	end := -1
	for i := pos; i < len(expr); i++ {
		switch expr[i] {
		case '(':
			depth++
		case ')':
			depth--
			if depth < 0 {
				return nil, pos, parseError{message: "parenthesis mismatch"}
			}
			if depth == 0 {
				end = i
				break
			}
		}
		if end >= 0 {
			break
		}
	}

	if end < 0 {
		return nil, pos, parseError{message: "parenthesis mismatch"}
	}

	node, err := parseFilterContent(expr[pos+1 : end])
	if err != nil {
		return nil, pos, err
	}
	return node, end + 1, nil
}

func parseFilterContent(content string) (filterExpr, error) {
	if content == "" {
		return nil, parseError{message: "empty filter"}
	}

	switch content[0] {
	case '&':
		nodes, err := parseFilterList(content[1:])
		if err != nil {
			return nil, err
		}
		if len(nodes) == 0 {
			return nil, parseError{message: "expected at least one nested filter"}
		}
		return filterAnd{nodes: nodes}, nil
	case '|':
		nodes, err := parseFilterList(content[1:])
		if err != nil {
			return nil, err
		}
		if len(nodes) == 0 {
			return nil, parseError{message: "expected at least one nested filter"}
		}
		return filterOr{nodes: nodes}, nil
	case '!':
		node, next, err := parseFilterAt(content, 1)
		if err != nil {
			return nil, err
		}
		if next != len(content) {
			return nil, parseError{message: "not operator has more than one filter"}
		}
		return filterNot{node: node}, nil
	default:
		return parseItem(content)
	}
}

func parseFilterList(content string) ([]filterExpr, error) {
	var nodes []filterExpr
	for pos := 0; pos < len(content); {
		node, next, err := parseFilterAt(content, pos)
		if err != nil {
			return nil, err
		}
		nodes = append(nodes, node)
		pos = next
	}
	return nodes, nil
}

func parseItem(content string) (filterExpr, error) {
	opIndex := -1
	op := byte(0)
	for i := 0; i < len(content); i++ {
		switch content[i] {
		case '=', '~', '>', '<':
			opIndex = i
			op = content[i]
			i = len(content)
		}
	}
	if opIndex < 0 {
		return nil, parseError{message: "error in item syntax"}
	}

	attr := content[:opIndex]
	if attr == "" {
		return nil, parseError{message: "error in item syntax"}
	}

	opText := string(op)
	if op == '~' || op == '>' || op == '<' {
		if opIndex+1 >= len(content) || content[opIndex+1] != '=' {
			return nil, parseError{message: "error in item syntax"}
		}
		opText += "="
	}

	rawValue := content[opIndex+len(opText):]
	value, wildcard, err := parseItemValue(rawValue)
	if err != nil {
		return nil, err
	}

	return filterItem{attr: attr, op: opText, value: value, wildcard: wildcard}, nil
}

func parseItemValue(raw string) (string, *wildcardPattern, error) {
	if raw == "*" {
		return "*", nil, nil
	}

	var decoded strings.Builder
	var parts []string
	var current strings.Builder
	sawWildcard := false

	for i := 0; i < len(raw); i++ {
		ch := raw[i]
		switch ch {
		case '\\':
			if i+2 >= len(raw) {
				return "", nil, parseError{message: "incomplete escape sequence"}
			}
			decodedByte, ok := decodeHexByte(raw[i+1], raw[i+2])
			if !ok {
				return "", nil, parseError{message: "invalid escape sequence"}
			}
			decoded.WriteByte(decodedByte)
			current.WriteByte(decodedByte)
			i += 2
		case '*':
			sawWildcard = true
			decoded.WriteByte('*')
			parts = append(parts, current.String())
			current.Reset()
		default:
			decoded.WriteByte(ch)
			current.WriteByte(ch)
		}
	}

	if !sawWildcard {
		return decoded.String(), nil, nil
	}

	parts = append(parts, current.String())
	return decoded.String(), &wildcardPattern{
		parts:        parts,
		leadingStar:  strings.HasPrefix(raw, "*"),
		trailingStar: strings.HasSuffix(raw, "*"),
	}, nil
}

func decodeHexByte(high, low byte) (byte, bool) {
	hi, ok := decodeHexDigit(high)
	if !ok {
		return 0, false
	}
	lo, ok := decodeHexDigit(low)
	if !ok {
		return 0, false
	}
	return hi<<4 | lo, true
}

func decodeHexDigit(ch byte) (byte, bool) {
	switch {
	case '0' <= ch && ch <= '9':
		return ch - '0', true
	case 'a' <= ch && ch <= 'f':
		return 10 + ch - 'a', true
	case 'A' <= ch && ch <= 'F':
		return 10 + ch - 'A', true
	default:
		return 0, false
	}
}

func (n filterAnd) match(attrs orderedAttrs) bool {
	for _, node := range n.nodes {
		if !node.match(attrs) {
			return false
		}
	}
	return true
}

func (n filterOr) match(attrs orderedAttrs) bool {
	for _, node := range n.nodes {
		if node.match(attrs) {
			return true
		}
	}
	return false
}

func (n filterNot) match(attrs orderedAttrs) bool {
	return !n.node.match(attrs)
}

func (n filterItem) match(attrs orderedAttrs) bool {
	actual, ok := attrs.get(n.attr)
	if !ok {
		return false
	}

	switch n.op {
	case "=":
		if n.value == "*" {
			return true
		}
		if n.wildcard != nil {
			return actual != nil && n.wildcard.matches(*actual)
		}
		return actual != nil && *actual == n.value
	case "~=":
		return actual != nil && levenshteinLTE(n.value, *actual, 2)
	case ">=":
		return actual != nil && *actual >= n.value
	case "<=":
		return actual != nil && *actual <= n.value
	default:
		return false
	}
}

func (p wildcardPattern) matches(actual string) bool {
	nonEmpty := make([]string, 0, len(p.parts))
	for _, part := range p.parts {
		if part != "" {
			nonEmpty = append(nonEmpty, part)
		}
	}
	if len(nonEmpty) == 0 {
		return true
	}

	pos := 0
	for i, part := range nonEmpty {
		isFirst := i == 0
		isLast := i == len(nonEmpty)-1
		if isFirst && !p.leadingStar {
			if !strings.HasPrefix(actual[pos:], part) {
				return false
			}
			pos += len(part)
			continue
		}
		if isLast && !p.trailingStar {
			return strings.HasSuffix(actual[pos:], part)
		}
		idx := strings.Index(actual[pos:], part)
		if idx < 0 {
			return false
		}
		pos += idx + len(part)
	}
	return true
}

func levenshteinLTE(a, b string, maxDistance int) bool {
	ra := []rune(a)
	rb := []rune(b)
	if abs(len(ra)-len(rb)) > maxDistance {
		return false
	}

	prev := make([]int, len(rb)+1)
	curr := make([]int, len(rb)+1)
	for j := range prev {
		prev[j] = j
	}

	for i := 1; i <= len(ra); i++ {
		curr[0] = i
		rowMin := curr[0]
		for j := 1; j <= len(rb); j++ {
			cost := 0
			if ra[i-1] != rb[j-1] {
				cost = 1
			}
			deletion := prev[j] + 1
			insertion := curr[j-1] + 1
			substitution := prev[j-1] + cost
			value := min3(deletion, insertion, substitution)
			curr[j] = value
			if value < rowMin {
				rowMin = value
			}
		}
		if rowMin > maxDistance {
			return false
		}
		copy(prev, curr)
	}

	return prev[len(rb)] <= maxDistance
}

func min3(a, b, c int) int {
	if a < b {
		if a < c {
			return a
		}
		return c
	}
	if b < c {
		return b
	}
	return c
}

func abs(n int) int {
	if n < 0 {
		return -n
	}
	return n
}

func inspectAttrs(attrs orderedAttrs) string {
	parts := make([]string, 0, attrs.len())
	for _, item := range attrs.items {
		parts = append(parts, formatKey(item.key)+formatValue(item.value))
	}
	return "{" + strings.Join(parts, ", ") + "}"
}

func formatKey(key string) string {
	if isRubySymbolName(key) {
		return key + ": "
	}
	return fmt.Sprintf("%q => ", key)
}

func formatValue(value *string) string {
	if value == nil {
		return "nil"
	}
	return fmt.Sprintf("%q", *value)
}

func isRubySymbolName(key string) bool {
	if key == "" {
		return false
	}
	for i := 0; i < len(key); i++ {
		ch := key[i]
		if i == 0 {
			if !(ch == '_' || ('a' <= ch && ch <= 'z') || ('A' <= ch && ch <= 'Z')) {
				return false
			}
			continue
		}
		if !(ch == '_' || ('a' <= ch && ch <= 'z') || ('A' <= ch && ch <= 'Z') || ('0' <= ch && ch <= '9')) {
			return false
		}
	}
	return true
}

func parseCSVHeader(line string) []string {
	return parseCSVLine(strings.TrimPrefix(line, "\ufeff"))
}

func parseCSVLine(line string) []string {
	reader := csv.NewReader(strings.NewReader(line))
	fields, err := reader.Read()
	if err != nil {
		return []string{line}
	}
	return fields
}

func rowToAttrs(headers, row []string) orderedAttrs {
	attrs := newOrderedAttrs()
	for i, header := range headers {
		value := ""
		if i < len(row) {
			value = row[i]
		}
		attrs.add(header, &value)
	}
	return attrs
}

func parseLTSVLine(line string) orderedAttrs {
	attrs := newOrderedAttrs()
	if line == "" {
		return attrs
	}
	for _, entry := range strings.Split(line, "\t") {
		idx := strings.IndexByte(entry, ':')
		if idx < 0 {
			continue
		}
		key := entry[:idx]
		value := entry[idx+1:]
		attrs.add(key, unescapeLTSVValue(value))
	}
	return attrs
}

func unescapeLTSVValue(value string) *string {
	if value == "" {
		return nil
	}
	var out strings.Builder
	for i := 0; i < len(value); i++ {
		if value[i] != '\\' {
			out.WriteByte(value[i])
			continue
		}
		if i+1 >= len(value) {
			out.WriteByte('\\')
			break
		}
		switch value[i+1] {
		case 'r':
			out.WriteByte('\r')
		case 'n':
			out.WriteByte('\n')
		case 't':
			out.WriteByte('\t')
		case '\\':
			out.WriteByte('\\')
		default:
			out.WriteByte('\\')
			out.WriteByte(value[i+1])
		}
		i++
	}
	result := out.String()
	if result == "" {
		return nil
	}
	return &result
}

func detectFormat(inputPath string) formatKind {
	lower := strings.ToLower(inputPath)
	if strings.HasSuffix(lower, ".csv") || strings.HasSuffix(lower, ".csv.xz") {
		return formatCSV
	}
	if strings.HasSuffix(lower, ".ltsv") || strings.HasSuffix(lower, ".ltsv.xz") {
		return formatLTSV
	}
	return formatLTSV
}

func phaseLine(phase string, started time.Time) string {
	elapsed := time.Since(started).Nanoseconds()
	return fmt.Sprintf("phase=%s t=%d elapsed_ns=%d", phase, elapsed, elapsed)
}

type inputSource struct {
	reader *bufio.Reader
	cmd    *exec.Cmd
	stderr *bytes.Buffer
	file   io.Closer
	closed bool
}

func openInput(path string) (*inputSource, error) {
	if strings.HasSuffix(strings.ToLower(path), ".xz") {
		cmd := exec.Command("xz", "-dc", path)
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			return nil, err
		}
		stderr := &bytes.Buffer{}
		cmd.Stderr = stderr
		if err := cmd.Start(); err != nil {
			return nil, err
		}
		return &inputSource{
			reader: bufio.NewReader(stdout),
			cmd:    cmd,
			stderr: stderr,
		}, nil
	}

	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	return &inputSource{
		reader: bufio.NewReader(file),
		file:   file,
	}, nil
}

func (s *inputSource) close() error {
	if s.closed {
		return nil
	}
	s.closed = true

	if s.file != nil {
		return s.file.Close()
	}
	if s.cmd != nil {
		err := s.cmd.Wait()
		if err != nil {
			if s.stderr != nil && s.stderr.Len() > 0 {
				return fmt.Errorf("xz failed for input: %s", strings.TrimSpace(s.stderr.String()))
			}
			return err
		}
	}
	return nil
}

func run(args []string, stdout, stderr io.Writer) error {
	started := time.Now()
	options, err := parseArgs(args)
	if err != nil {
		return err
	}
	if options.help {
		_, err := fmt.Fprintln(stdout, "Usage: ldap_filter [options] FILTER INPUT")
		return err
	}

	filter := options.filter
	if filter == "" && len(options.positional) > 0 {
		filter = options.positional[0]
	}
	inputPath := options.input
	if inputPath == "" && len(options.positional) > 1 {
		inputPath = options.positional[1]
	}
	if filter == "" || inputPath == "" {
		return errors.New("filter and input path are required")
	}

	fmt.Fprintln(stderr, phaseLine("boot", started))
	format := options.format
	if format == formatAuto {
		format = detectFormat(inputPath)
	}

	ast, err := parseFilter(filter)
	if err != nil {
		return err
	}
	source, err := openInput(inputPath)
	if err != nil {
		return err
	}
	defer source.close()

	fmt.Fprintln(stderr, phaseLine("ready", started))
	if err := processInput(source.reader, format, ast, stdout); err != nil {
		return err
	}
	if err := source.close(); err != nil {
		return err
	}
	fmt.Fprintln(stderr, phaseLine("done", started))
	return nil
}

func processInput(reader *bufio.Reader, format formatKind, ast filterExpr, stdout io.Writer) error {
	switch format {
	case formatCSV:
		return processCSV(reader, ast, stdout)
	case formatLTSV:
		return processLTSV(reader, ast, stdout)
	default:
		return errors.New("invalid format")
	}
}

func processCSV(reader *bufio.Reader, ast filterExpr, stdout io.Writer) error {
	csvReader := csv.NewReader(reader)
	headers, err := csvReader.Read()
	if err != nil {
		if errors.Is(err, io.EOF) {
			return nil
		}
		return err
	}
	if len(headers) > 0 {
		headers[0] = strings.TrimPrefix(headers[0], "\ufeff")
	}

	for {
		row, err := csvReader.Read()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		attrs := rowToAttrs(headers, row)
		if ast.match(attrs) {
			fmt.Fprintln(stdout, inspectAttrs(attrs))
		}
	}
}

func processLTSV(reader *bufio.Reader, ast filterExpr, stdout io.Writer) error {
	for {
		line, err := reader.ReadString('\n')
		if errors.Is(err, io.EOF) && line == "" {
			return nil
		}
		if err != nil && !errors.Is(err, io.EOF) {
			return err
		}
		line = strings.TrimRight(line, "\r\n")
		attrs := parseLTSVLine(line)
		if ast.match(attrs) {
			fmt.Fprintln(stdout, inspectAttrs(attrs))
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
	}
}

func parseArgs(args []string) (cliOptions, error) {
	fs := flag.NewFlagSet("ldap_filter", flag.ContinueOnError)
	fs.SetOutput(io.Discard)

	var options cliOptions
	fs.StringVar(&options.filter, "filter", "", "LDAP search filter")
	fs.StringVar(&options.input, "input", "", "input log file")
	format := fs.String("format", "auto", "input format")
	fs.Bool("jit", false, "ignored")
	fs.Bool("no-jit", false, "ignored")
	fs.Bool("yjit", false, "ignored")
	fs.Bool("no-yjit", false, "ignored")
	fs.Bool("yjit-stats", false, "ignored")
	help := fs.Bool("help", false, "show help")

	if err := fs.Parse(args); err != nil {
		return options, err
	}
	options.help = *help
	options.format = formatKind(*format)
	switch options.format {
	case formatAuto, formatCSV, formatLTSV:
	default:
		return options, fmt.Errorf("unsupported format: %s", *format)
	}
	options.positional = fs.Args()
	return options, nil
}

type cliOptions struct {
	filter     string
	input      string
	format     formatKind
	help       bool
	positional []string
}

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
