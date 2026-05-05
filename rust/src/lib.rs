use std::fmt;
use std::fs::File;
use std::io::{self, BufRead, BufReader, Write};
use std::process::{Child, Command, Stdio};
use std::time::Instant;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FormatKind {
    Auto,
    Csv,
    Ltsv,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FilterExpr {
    And(Vec<FilterExpr>),
    Or(Vec<FilterExpr>),
    Not(Box<FilterExpr>),
    Item(FilterItem),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FilterItem {
    pub attr: String,
    pub op: FilterOp,
    pub value: String,
    matcher: ValueMatcher,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FilterOp {
    Eq,
    Approx,
    Ge,
    Le,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ValueMatcher {
    Presence,
    Exact(String),
    Wildcard(WildcardPattern),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct WildcardPattern {
    parts: Vec<String>,
    leading_star: bool,
    trailing_star: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OrderedAttrs {
    items: Vec<(String, Option<String>)>,
}

#[derive(Debug, Clone)]
pub struct ParseError {
    pub message: String,
    pub position: usize,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.position == usize::MAX {
            write!(f, "{}", self.message)
        } else {
            write!(f, "{} at position {}", self.message, self.position)
        }
    }
}

impl std::error::Error for ParseError {}

impl OrderedAttrs {
    pub fn new() -> Self {
        Self { items: Vec::new() }
    }

    pub fn push(&mut self, key: impl Into<String>, value: Option<impl Into<String>>) {
        self.items.push((key.into(), value.map(Into::into)));
    }

    pub fn get(&self, key: &str) -> Option<Option<&str>> {
        self.items
            .iter()
            .find(|(candidate, _)| candidate == key)
            .map(|(_, value)| value.as_deref())
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, Option<&str>)> {
        self.items
            .iter()
            .map(|(key, value)| (key.as_str(), value.as_deref()))
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }
}

pub fn parse_filter(input: &str) -> Result<FilterExpr, ParseError> {
    let mut parser = Parser::new(input);
    let expr = parser.parse_filter()?;
    parser.expect_eof()?;
    Ok(expr)
}

pub fn evaluate_filter(expr: &FilterExpr, attrs: &OrderedAttrs) -> bool {
    match expr {
        FilterExpr::And(nodes) => nodes.iter().all(|node| evaluate_filter(node, attrs)),
        FilterExpr::Or(nodes) => nodes.iter().any(|node| evaluate_filter(node, attrs)),
        FilterExpr::Not(node) => !evaluate_filter(node, attrs),
        FilterExpr::Item(item) => item.matches(attrs),
    }
}

pub fn inspect_attrs(attrs: &OrderedAttrs) -> String {
    let mut parts = Vec::with_capacity(attrs.len());
    for (key, value) in attrs.iter() {
        parts.push(format!(
            "{}{}",
            format_ruby_key(key),
            format_ruby_value(value)
        ));
    }
    format!("{{{}}}", parts.join(", "))
}

pub fn parse_csv_header(line: &str) -> Vec<String> {
    parse_csv_line(line.trim_start_matches('\u{feff}'))
}

pub fn parse_csv_line(line: &str) -> Vec<String> {
    let mut cells = Vec::new();
    let mut cell = String::new();
    let mut chars = line.chars().peekable();
    let mut quoted = false;

    while let Some(ch) = chars.next() {
        if quoted {
            if ch == '"' {
                if matches!(chars.peek(), Some('"')) {
                    cell.push('"');
                    chars.next();
                } else {
                    quoted = false;
                }
            } else {
                cell.push(ch);
            }
        } else if ch == ',' {
            cells.push(std::mem::take(&mut cell));
        } else if ch == '"' {
            quoted = true;
        } else {
            cell.push(ch);
        }
    }

    cells.push(cell);
    cells
}

pub fn row_to_attrs(headers: &[String], row: &[String]) -> OrderedAttrs {
    let mut attrs = OrderedAttrs::new();
    for (index, header) in headers.iter().enumerate() {
        attrs.push(
            header.clone(),
            Some(row.get(index).cloned().unwrap_or_default()),
        );
    }
    attrs
}

pub fn parse_ltsv_line(line: &str) -> OrderedAttrs {
    let mut attrs = OrderedAttrs::new();
    if line.is_empty() {
        return attrs;
    }

    for entry in line.split('\t') {
        let Some(index) = entry.find(':') else {
            continue;
        };
        let key = &entry[..index];
        let value = &entry[index + 1..];
        attrs.push(
            key.to_string(),
            normalize_ltsv_value(unescape_ltsv_value(value)),
        );
    }

    attrs
}

pub fn detect_format(input_path: &str) -> FormatKind {
    let lower = input_path.to_ascii_lowercase();
    if lower.ends_with(".csv") || lower.ends_with(".csv.xz") {
        return FormatKind::Csv;
    }
    if lower.ends_with(".ltsv") || lower.ends_with(".ltsv.xz") {
        return FormatKind::Ltsv;
    }
    FormatKind::Ltsv
}

pub fn phase_line(phase: &str, started: Instant) -> String {
    let elapsed_ns = elapsed_ns(started);
    format!("phase={} t={} elapsed_ns={}", phase, elapsed_ns, elapsed_ns)
}

pub fn run_with_io(
    args: &[String],
    stdout: &mut dyn Write,
    stderr: &mut dyn Write,
) -> Result<(), String> {
    let started = Instant::now();
    let options = parse_args(args)?;

    if options.help {
        writeln!(stdout, "Usage: ldf [options] FILTER INPUT").map_err(io_error)?;
        return Ok(());
    }

    let filter = options
        .filter
        .or_else(|| options.positional.get(0).cloned())
        .ok_or_else(|| "filter and input path are required".to_string())?;
    let input = options
        .input
        .or_else(|| options.positional.get(1).cloned())
        .ok_or_else(|| "filter and input path are required".to_string())?;

    writeln!(stderr, "{}", phase_line("boot", started)).map_err(io_error)?;

    let format = match options.format {
        FormatKind::Auto => detect_format(&input),
        other => other,
    };
    let ast = parse_filter(&filter).map_err(|err| err.to_string())?;
    let mut input_source = InputSource::open(&input)?;

    writeln!(stderr, "{}", phase_line("ready", started)).map_err(io_error)?;

    process_input(&mut input_source, format, &ast, stdout)?;
    input_source.finish()?;

    writeln!(stderr, "{}", phase_line("done", started)).map_err(io_error)?;
    Ok(())
}

fn process_input(
    input_source: &mut InputSource,
    format: FormatKind,
    ast: &FilterExpr,
    stdout: &mut dyn Write,
) -> Result<(), String> {
    match format {
        FormatKind::Csv => process_csv(input_source, ast, stdout),
        FormatKind::Ltsv => process_ltsv(input_source, ast, stdout),
        FormatKind::Auto => unreachable!(),
    }
}

fn process_csv(
    input_source: &mut InputSource,
    ast: &FilterExpr,
    stdout: &mut dyn Write,
) -> Result<(), String> {
    let reader = input_source.reader_mut();
    let mut line = String::new();

    let Some(headers_line) = read_next_line(reader, &mut line)? else {
        return Ok(());
    };
    let headers = parse_csv_header(&headers_line);

    while let Some(row_line) = read_next_line(reader, &mut line)? {
        if row_line.is_empty() {
            continue;
        }
        let row = parse_csv_line(&row_line);
        let attrs = row_to_attrs(&headers, &row);
        if evaluate_filter(ast, &attrs) {
            writeln!(stdout, "{}", inspect_attrs(&attrs)).map_err(io_error)?;
        }
    }

    Ok(())
}

fn process_ltsv(
    input_source: &mut InputSource,
    ast: &FilterExpr,
    stdout: &mut dyn Write,
) -> Result<(), String> {
    let reader = input_source.reader_mut();
    let mut line = String::new();

    while let Some(row_line) = read_next_line(reader, &mut line)? {
        let attrs = parse_ltsv_line(&row_line);
        if evaluate_filter(ast, &attrs) {
            writeln!(stdout, "{}", inspect_attrs(&attrs)).map_err(io_error)?;
        }
    }

    Ok(())
}

fn read_next_line(reader: &mut dyn BufRead, buffer: &mut String) -> Result<Option<String>, String> {
    buffer.clear();
    let read = reader.read_line(buffer).map_err(io_error)?;
    if read == 0 {
        return Ok(None);
    }

    if buffer.ends_with('\n') {
        buffer.pop();
        if buffer.ends_with('\r') {
            buffer.pop();
        }
    }

    Ok(Some(std::mem::take(buffer)))
}

fn format_ruby_key(key: &str) -> String {
    if is_ruby_symbol_name(key) {
        format!("{}: ", key)
    } else {
        format!("\"{}\" => ", escape_ruby_string(key))
    }
}

fn format_ruby_value(value: Option<&str>) -> String {
    match value {
        Some(text) => format!("\"{}\"", escape_ruby_string(text)),
        None => "nil".to_string(),
    }
}

fn is_ruby_symbol_name(text: &str) -> bool {
    let mut chars = text.chars();
    match chars.next() {
        Some(ch) if ch == '_' || ch.is_ascii_alphabetic() => {}
        _ => return false,
    }

    chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn escape_ruby_string(text: &str) -> String {
    text.replace('\\', "\\\\").replace('"', "\\\"")
}

fn normalize_ltsv_value(value: Option<String>) -> Option<String> {
    match value {
        Some(text) if text.is_empty() => None,
        other => other,
    }
}

fn unescape_ltsv_value(value: &str) -> Option<String> {
    if value.is_empty() {
        return None;
    }

    let mut result = String::new();
    let mut chars = value.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch != '\\' {
            result.push(ch);
            continue;
        }

        let Some(escaped) = chars.next() else {
            result.push('\\');
            break;
        };

        match escaped {
            'r' => result.push('\r'),
            'n' => result.push('\n'),
            't' => result.push('\t'),
            '\\' => result.push('\\'),
            other => {
                result.push('\\');
                result.push(other);
            }
        }
    }

    Some(result)
}

fn elapsed_ns(started: Instant) -> u128 {
    started.elapsed().as_nanos()
}

fn io_error(err: io::Error) -> String {
    err.to_string()
}

struct InputSource {
    reader: Box<dyn BufRead>,
    child: Option<Child>,
}

impl InputSource {
    fn open(path: &str) -> Result<Self, String> {
        if path.to_ascii_lowercase().ends_with(".xz") {
            let mut child = Command::new("xz")
                .args(["-dc", path])
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .spawn()
                .map_err(io_error)?;
            let stdout = child
                .stdout
                .take()
                .ok_or_else(|| "failed to capture xz stdout".to_string())?;
            return Ok(Self {
                reader: Box::new(BufReader::new(stdout)),
                child: Some(child),
            });
        }

        let file = File::open(path).map_err(io_error)?;
        Ok(Self {
            reader: Box::new(BufReader::new(file)),
            child: None,
        })
    }

    fn reader_mut(&mut self) -> &mut dyn BufRead {
        &mut *self.reader
    }

    fn finish(mut self) -> Result<(), String> {
        if let Some(mut child) = self.child.take() {
            let status = child.wait().map_err(io_error)?;
            if !status.success() {
                return Err("xz failed".to_string());
            }
        }
        Ok(())
    }
}

#[derive(Debug)]
struct CliOptions {
    filter: Option<String>,
    input: Option<String>,
    format: FormatKind,
    help: bool,
    positional: Vec<String>,
}

impl Default for CliOptions {
    fn default() -> Self {
        Self {
            filter: None,
            input: None,
            format: FormatKind::Auto,
            help: false,
            positional: Vec::new(),
        }
    }
}

fn parse_args(args: &[String]) -> Result<CliOptions, String> {
    let mut options = CliOptions {
        format: FormatKind::Auto,
        ..CliOptions::default()
    };

    let mut index = 0usize;
    while index < args.len() {
        let arg = &args[index];
        match arg.as_str() {
            "--filter" => {
                options.filter = Some(next_arg(args, &mut index, "--filter")?);
            }
            "--input" => {
                options.input = Some(next_arg(args, &mut index, "--input")?);
            }
            "--format" => {
                let value = next_arg(args, &mut index, "--format")?;
                options.format = parse_format(&value)?;
            }
            "--jit" | "--no-jit" | "--yjit" | "--no-yjit" | "--yjit-stats" => {}
            "--help" => {
                options.help = true;
            }
            _ if arg.starts_with("--") => {
                return Err(format!("unknown option: {}", arg));
            }
            _ => options.positional.push(arg.clone()),
        }
        index += 1;
    }

    Ok(options)
}

fn next_arg(args: &[String], index: &mut usize, option: &str) -> Result<String, String> {
    let next = *index + 1;
    if next >= args.len() {
        return Err(format!("missing value for {}", option));
    }

    *index = next;
    Ok(args[next].clone())
}

fn parse_format(value: &str) -> Result<FormatKind, String> {
    match value {
        "auto" => Ok(FormatKind::Auto),
        "csv" => Ok(FormatKind::Csv),
        "ltsv" => Ok(FormatKind::Ltsv),
        other => Err(format!("unsupported format: {}", other)),
    }
}

impl FilterItem {
    fn matches(&self, attrs: &OrderedAttrs) -> bool {
        let Some(actual) = attrs.get(&self.attr) else {
            return false;
        };

        match self.op {
            FilterOp::Eq => match &self.matcher {
                ValueMatcher::Presence => true,
                ValueMatcher::Exact(expected) => actual == Some(expected.as_str()),
                ValueMatcher::Wildcard(pattern) => {
                    actual.is_some_and(|value| pattern.matches(value))
                }
            },
            FilterOp::Approx => actual
                .and_then(|value| Some(levenshtein_distance_lte(value, &self.value, 2)))
                .unwrap_or(false),
            FilterOp::Ge => actual.is_some_and(|value| value >= self.value.as_str()),
            FilterOp::Le => actual.is_some_and(|value| value <= self.value.as_str()),
        }
    }
}

impl WildcardPattern {
    fn matches(&self, actual: &str) -> bool {
        let non_empty: Vec<&str> = self
            .parts
            .iter()
            .map(String::as_str)
            .filter(|part| !part.is_empty())
            .collect();
        if non_empty.is_empty() {
            return true;
        }

        let mut position = 0usize;
        for (index, part) in non_empty.iter().enumerate() {
            let is_first = index == 0;
            let is_last = index == non_empty.len() - 1;

            if is_first && !self.leading_star {
                if !actual[position..].starts_with(part) {
                    return false;
                }
                position += part.len();
                continue;
            }

            if is_last && !self.trailing_star {
                return actual[position..].ends_with(part);
            }

            let Some(found) = actual[position..].find(part) else {
                return false;
            };
            position += found + part.len();
        }

        true
    }
}

fn levenshtein_distance_lte(a: &str, b: &str, max_distance: usize) -> bool {
    let a_chars: Vec<char> = a.chars().collect();
    let b_chars: Vec<char> = b.chars().collect();
    if a_chars.len().abs_diff(b_chars.len()) > max_distance {
        return false;
    }

    let mut prev: Vec<usize> = (0..=b_chars.len()).collect();
    let mut curr = vec![0; b_chars.len() + 1];

    for (i, a_ch) in a_chars.iter().enumerate() {
        curr[0] = i + 1;
        let mut row_min = curr[0];

        for (j, b_ch) in b_chars.iter().enumerate() {
            let cost = usize::from(a_ch != b_ch);
            let delete = prev[j + 1] + 1;
            let insert = curr[j] + 1;
            let substitute = prev[j] + cost;
            let value = delete.min(insert).min(substitute);
            curr[j + 1] = value;
            row_min = row_min.min(value);
        }

        if row_min > max_distance {
            return false;
        }

        std::mem::swap(&mut prev, &mut curr);
    }

    prev[b_chars.len()] <= max_distance
}

impl Parser {
    fn new(input: &str) -> Self {
        Self {
            chars: input.chars().collect(),
            pos: 0,
        }
    }

    fn parse_filter(&mut self) -> Result<FilterExpr, ParseError> {
        self.expect('(')?;
        let expr = self.parse_filter_comp()?;
        self.expect(')')?;
        Ok(expr)
    }

    fn parse_filter_comp(&mut self) -> Result<FilterExpr, ParseError> {
        match self.peek() {
            Some('&') => {
                self.next();
                self.parse_group_list().map(FilterExpr::And)
            }
            Some('|') => {
                self.next();
                self.parse_group_list().map(FilterExpr::Or)
            }
            Some('!') => {
                self.next();
                let node = self.parse_filter()?;
                Ok(FilterExpr::Not(Box::new(node)))
            }
            _ => self.parse_item(),
        }
    }

    fn parse_group_list(&mut self) -> Result<Vec<FilterExpr>, ParseError> {
        let mut nodes = Vec::new();
        while matches!(self.peek(), Some('(')) {
            nodes.push(self.parse_filter()?);
        }

        if nodes.is_empty() {
            return Err(self.error("expected at least one nested filter"));
        }

        Ok(nodes)
    }

    fn parse_item(&mut self) -> Result<FilterExpr, ParseError> {
        let attr = self.take_until_operator()?;
        let op = match self.next() {
            Some('=') => FilterOp::Eq,
            Some('~') => {
                self.expect('=')?;
                FilterOp::Approx
            }
            Some('>') => {
                self.expect('=')?;
                FilterOp::Ge
            }
            Some('<') => {
                self.expect('=')?;
                FilterOp::Le
            }
            _ => return Err(self.error("expected comparison operator")),
        };

        let raw_value = self.take_until(')')?;
        let (value, matcher) = parse_item_value(
            &raw_value,
            self.pos.saturating_sub(raw_value.chars().count()),
        )?;
        Ok(FilterExpr::Item(FilterItem {
            attr,
            op,
            value,
            matcher,
        }))
    }

    fn take_until_operator(&mut self) -> Result<String, ParseError> {
        let start = self.pos;
        while let Some(ch) = self.peek() {
            if matches!(ch, '=' | '~' | '>' | '<') {
                break;
            }
            if ch == ')' {
                return Err(self.error("unexpected ')' in attribute name"));
            }
            self.next();
        }

        if self.pos == start {
            return Err(self.error("expected attribute name"));
        }

        Ok(self.chars[start..self.pos].iter().collect())
    }

    fn take_until(&mut self, terminator: char) -> Result<String, ParseError> {
        let start = self.pos;
        while let Some(ch) = self.peek() {
            if ch == terminator {
                break;
            }
            self.next();
        }

        Ok(self.chars[start..self.pos].iter().collect())
    }

    fn expect(&mut self, ch: char) -> Result<(), ParseError> {
        match self.next() {
            Some(actual) if actual == ch => Ok(()),
            Some(actual) => Err(self.error_expected(ch, actual)),
            None => Err(self.error_expected(ch, '\0')),
        }
    }

    fn expect_eof(&self) -> Result<(), ParseError> {
        if self.pos == self.chars.len() {
            Ok(())
        } else {
            Err(self.error("unexpected trailing input"))
        }
    }

    fn next(&mut self) -> Option<char> {
        let ch = self.peek();
        if ch.is_some() {
            self.pos += 1;
        }
        ch
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn error(&self, message: &str) -> ParseError {
        ParseError {
            message: message.to_string(),
            position: self.pos,
        }
    }

    fn error_expected(&self, expected: char, actual: char) -> ParseError {
        ParseError {
            message: format!("expected {:?}, found {:?}", expected, actual),
            position: self.pos,
        }
    }
}

struct Parser {
    chars: Vec<char>,
    pos: usize,
}

fn parse_item_value(raw: &str, position: usize) -> Result<(String, ValueMatcher), ParseError> {
    if raw == "*" {
        return Ok(("*".to_string(), ValueMatcher::Presence));
    }

    let mut decoded = String::new();
    let mut segments = Vec::new();
    let mut current = String::new();
    let mut saw_wildcard = false;
    let mut chars = raw.chars().peekable();

    while let Some(ch) = chars.next() {
        match ch {
            '\\' => {
                let Some(high) = chars.next() else {
                    return Err(ParseError {
                        message: "incomplete escape sequence".to_string(),
                        position,
                    });
                };
                let Some(low) = chars.next() else {
                    return Err(ParseError {
                        message: "incomplete escape sequence".to_string(),
                        position,
                    });
                };
                let decoded_char = decode_hex_escape(high, low).ok_or_else(|| ParseError {
                    message: format!("invalid escape sequence: \\{}{}", high, low),
                    position,
                })?;
                decoded.push(decoded_char);
                current.push(decoded_char);
            }
            '*' => {
                saw_wildcard = true;
                decoded.push('*');
                segments.push(std::mem::take(&mut current));
            }
            other => {
                decoded.push(other);
                current.push(other);
            }
        }
    }

    if !saw_wildcard {
        let exact = decoded.clone();
        return Ok((decoded, ValueMatcher::Exact(exact)));
    }

    segments.push(current);
    Ok((
        decoded,
        ValueMatcher::Wildcard(WildcardPattern {
            parts: segments,
            leading_star: raw.starts_with('*'),
            trailing_star: raw.ends_with('*'),
        }),
    ))
}

fn decode_hex_escape(high: char, low: char) -> Option<char> {
    let high = high.to_digit(16)?;
    let low = low.to_digit(16)?;
    char::from_u32(high * 16 + low)
}

impl FilterExpr {
    pub fn item(attr: impl Into<String>, op: FilterOp, value: impl Into<String>) -> Self {
        let attr = attr.into();
        let value = value.into();
        let matcher = match op {
            FilterOp::Eq if value == "*" => ValueMatcher::Presence,
            FilterOp::Eq if value.contains('*') => {
                let (decoded, matcher) =
                    parse_item_value(&value, 0).expect("valid wildcard pattern");
                debug_assert_eq!(decoded, value);
                matcher
            }
            _ => ValueMatcher::Exact(value.clone()),
        };
        Self::Item(FilterItem {
            attr,
            op,
            value,
            matcher,
        })
    }
}

impl fmt::Display for FilterExpr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FilterExpr::And(nodes) => write!(f, "(&{} )", nodes.len()),
            FilterExpr::Or(nodes) => write!(f, "(|{} )", nodes.len()),
            FilterExpr::Not(_) => write!(f, "(!...)"),
            FilterExpr::Item(item) => write!(f, "({} {:?} {})", item.attr, item.op, item.value),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_wildcard_and_presence_filters() {
        let wildcard = parse_filter("(host=www.*)").expect("parse wildcard");
        let presence = parse_filter("(host=*)").expect("parse presence");

        match wildcard {
            FilterExpr::Item(item) => {
                assert_eq!(item.attr, "host");
                assert_eq!(item.op, FilterOp::Eq);
                assert_eq!(item.value, "www.*");
            }
            other => panic!("unexpected node: {:?}", other),
        }

        match presence {
            FilterExpr::Item(item) => {
                assert_eq!(item.value, "*");
            }
            other => panic!("unexpected node: {:?}", other),
        }
    }

    #[test]
    fn evaluates_logical_expression_and_approximate_match() {
        let attrs = OrderedAttrs {
            items: vec![
                ("host".to_string(), Some("www.example.com".to_string())),
                ("status".to_string(), Some("200".to_string())),
                ("cn".to_string(), Some("foo bar".to_string())),
            ],
        };

        assert!(evaluate_filter(
            &parse_filter("(&(host=www.*)(status=200))").unwrap(),
            &attrs
        ));
        assert!(evaluate_filter(
            &parse_filter("(host~=www.example.com)").unwrap(),
            &attrs
        ));
    }

    #[test]
    fn formats_attrs_like_ruby() {
        let attrs = OrderedAttrs {
            items: vec![
                (
                    "time".to_string(),
                    Some("2022-04-10T00:00:05+09:00".to_string()),
                ),
                ("remote_addr".to_string(), Some("49.98.3.247".to_string())),
                ("http/2".to_string(), Some("h2".to_string())),
                ("empty".to_string(), None),
            ],
        };

        assert_eq!(
            inspect_attrs(&attrs),
            "{time: \"2022-04-10T00:00:05+09:00\", remote_addr: \"49.98.3.247\", \"http/2\" => \"h2\", empty: nil}"
        );
    }

    #[test]
    fn parses_csv_and_ltsv_rows() {
        let headers = parse_csv_header("\u{feff}host,pass,comment");
        let row = parse_csv_line("\"example,com\",\"tr\"\"ue\",tail");
        let attrs = row_to_attrs(&headers, &row);

        assert_eq!(attrs.get("host"), Some(Some("example,com")));
        assert_eq!(attrs.get("pass"), Some(Some("tr\"ue")));
        assert_eq!(attrs.get("comment"), Some(Some("tail")));

        let ltsv = parse_ltsv_line("host:example\\tcom\tpass:true\tcomment:line\\nnext\tempty:");
        assert_eq!(ltsv.get("host"), Some(Some("example\tcom")));
        assert_eq!(ltsv.get("pass"), Some(Some("true")));
        assert_eq!(ltsv.get("comment"), Some(Some("line\nnext")));
        assert_eq!(ltsv.get("empty"), Some(None));
    }
}
