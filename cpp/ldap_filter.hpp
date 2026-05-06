#pragma once

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <iomanip>
#include <iostream>
#include <memory>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace ldf {

class LdapFilterError : public std::runtime_error {
public:
  using std::runtime_error::runtime_error;
};

struct OrderedAttrs {
  std::vector<std::pair<std::string, std::optional<std::string>>> items;

  void add(std::string key, std::optional<std::string> value) {
    items.emplace_back(std::move(key), std::move(value));
  }

  bool contains(const std::string &key) const {
    return std::any_of(items.begin(), items.end(), [&](const auto &item) {
      return item.first == key;
    });
  }

  const std::optional<std::string> *findOptional(const std::string &key) const {
    for (const auto &item : items) {
      if (item.first == key) {
        return &item.second;
      }
    }
    return nullptr;
  }
};

struct ItemMatcher {
  enum class Kind {
    Exact,
    Presence,
    Wildcard,
  };

  Kind kind = Kind::Exact;
  std::vector<std::string> parts;
  bool leading_star = false;
  bool trailing_star = false;
};

struct FilterExpr;

inline bool wildcardMatches(const std::vector<std::string> &parts, bool leading_star, bool trailing_star,
                            const std::string &actual);
inline bool levenshteinAtMost(const std::string &left, const std::string &right, int limit);

struct FilterAnd {
  std::vector<std::unique_ptr<FilterExpr>> children;

  explicit FilterAnd(std::vector<std::unique_ptr<FilterExpr>> children)
      : children(std::move(children)) {}

  bool evaluate(const OrderedAttrs &attrs) const;
};

struct FilterOr {
  std::vector<std::unique_ptr<FilterExpr>> children;

  explicit FilterOr(std::vector<std::unique_ptr<FilterExpr>> children)
      : children(std::move(children)) {}

  bool evaluate(const OrderedAttrs &attrs) const;
};

struct FilterNot {
  std::unique_ptr<FilterExpr> child;

  explicit FilterNot(std::unique_ptr<FilterExpr> child) : child(std::move(child)) {}

  bool evaluate(const OrderedAttrs &attrs) const;
};

struct FilterItem {
  enum class Op {
    Eq,
    Approx,
    Ge,
    Le,
  };

  std::string attr;
  Op op = Op::Eq;
  std::string value;
  ItemMatcher matcher;

  FilterItem(std::string attr, Op op, std::string value, ItemMatcher matcher)
      : attr(std::move(attr)), op(op), value(std::move(value)), matcher(std::move(matcher)) {}

  bool evaluate(const OrderedAttrs &attrs) const;
};

struct FilterExpr {
  using Node = std::variant<FilterAnd, FilterOr, FilterNot, FilterItem>;

  Node node;

  explicit FilterExpr(FilterAnd value) : node(std::move(value)) {}
  explicit FilterExpr(FilterOr value) : node(std::move(value)) {}
  explicit FilterExpr(FilterNot value) : node(std::move(value)) {}
  explicit FilterExpr(FilterItem value) : node(std::move(value)) {}

  FilterExpr(const FilterExpr &) = delete;
  FilterExpr &operator=(const FilterExpr &) = delete;
  FilterExpr(FilterExpr &&) noexcept = default;
  FilterExpr &operator=(FilterExpr &&) noexcept = default;

  bool evaluate(const OrderedAttrs &attrs) const {
    return std::visit([&](const auto &value) { return value.evaluate(attrs); }, node);
  }
};

inline bool FilterAnd::evaluate(const OrderedAttrs &attrs) const {
  for (const auto &child : children) {
    if (!child->evaluate(attrs)) {
      return false;
    }
  }
  return true;
}

inline bool FilterOr::evaluate(const OrderedAttrs &attrs) const {
  for (const auto &child : children) {
    if (child->evaluate(attrs)) {
      return true;
    }
  }
  return false;
}

inline bool FilterNot::evaluate(const OrderedAttrs &attrs) const {
  return !child->evaluate(attrs);
}

inline bool FilterItem::evaluate(const OrderedAttrs &attrs) const {
  const auto *actual = attrs.findOptional(attr);

  if (op == Op::Eq) {
    if (matcher.kind == ItemMatcher::Kind::Presence) {
      return attrs.contains(attr);
    }
    if (actual == nullptr || !actual->has_value()) {
      return false;
    }
    if (matcher.kind == ItemMatcher::Kind::Wildcard) {
      return wildcardMatches(matcher.parts, matcher.leading_star, matcher.trailing_star, **actual);
    }
    return **actual == value;
  }

  if (actual == nullptr || !actual->has_value()) {
    return false;
  }

  const std::string &actual_value = **actual;
  switch (op) {
  case Op::Approx:
    return levenshteinAtMost(actual_value, value, 2);
  case Op::Ge:
    return actual_value >= value;
  case Op::Le:
    return actual_value <= value;
  case Op::Eq:
    break;
  }

  throw LdapFilterError("unsupported operator");
}

inline int hexValue(char c) {
  if ('0' <= c && c <= '9') {
    return c - '0';
  }
  if ('a' <= c && c <= 'f') {
    return 10 + (c - 'a');
  }
  if ('A' <= c && c <= 'F') {
    return 10 + (c - 'A');
  }
  return -1;
}

inline char decodeHexEscape(char high, char low, std::size_t position) {
  const int hi = hexValue(high);
  const int lo = hexValue(low);
  if (hi < 0 || lo < 0) {
    std::ostringstream oss;
    oss << "invalid escape sequence: \\" << high << low << " at position " << position;
    throw LdapFilterError(oss.str());
  }
  return static_cast<char>((hi << 4) | lo);
}

inline std::pair<std::string, ItemMatcher> parseItemValue(const std::string &raw, std::size_t position) {
  if (raw == "*") {
    return {"*", ItemMatcher{ItemMatcher::Kind::Presence}};
  }

  std::string decoded;
  std::vector<std::string> parts;
  std::string current;
  bool saw_wildcard = false;

  for (std::size_t i = 0; i < raw.size();) {
    const char ch = raw[i];
    if (ch == '\\') {
      if (i + 2 >= raw.size()) {
        std::ostringstream oss;
        oss << "incomplete escape sequence at position " << position;
        throw LdapFilterError(oss.str());
      }
      const char decoded_char = decodeHexEscape(raw[i + 1], raw[i + 2], position);
      decoded.push_back(decoded_char);
      current.push_back(decoded_char);
      i += 3;
      continue;
    }
    if (ch == '*') {
      saw_wildcard = true;
      decoded.push_back('*');
      parts.push_back(current);
      current.clear();
      ++i;
      continue;
    }
    decoded.push_back(ch);
    current.push_back(ch);
    ++i;
  }

  if (!saw_wildcard) {
    return {decoded, ItemMatcher{ItemMatcher::Kind::Exact}};
  }

  parts.push_back(current);
  ItemMatcher matcher;
  matcher.kind = ItemMatcher::Kind::Wildcard;
  matcher.parts = std::move(parts);
  matcher.leading_star = !raw.empty() && raw.front() == '*';
  matcher.trailing_star = !raw.empty() && raw.back() == '*';
  return {decoded, std::move(matcher)};
}

inline bool wildcardMatches(const std::vector<std::string> &parts, bool leading_star, bool trailing_star,
                            const std::string &actual) {
  if (parts.empty()) {
    return actual.empty();
  }

  std::size_t start = 0;
  std::size_t end = parts.size() - 1;
  std::size_t offset = 0;

  if (!leading_star) {
    if (!actual.starts_with(parts[0])) {
      return false;
    }
    offset = parts[0].size();
    start = 1;
  }

  if (!trailing_star) {
    const std::string &last = parts[end];
    if (!last.empty() && !actual.ends_with(last)) {
      return false;
    }
    if (end > 0) {
      --end;
    } else if (!leading_star) {
      return actual == parts[0];
    }
  }

  for (std::size_t i = start; i <= end && i < parts.size(); ++i) {
    const std::string &part = parts[i];
    if (part.empty()) {
      continue;
    }
    const std::size_t found = actual.find(part, offset);
    if (found == std::string::npos) {
      return false;
    }
    offset = found + part.size();
  }

  return true;
}

inline bool levenshteinAtMost(const std::string &left, const std::string &right, int limit) {
  const int left_len = static_cast<int>(left.size());
  const int right_len = static_cast<int>(right.size());
  if (std::abs(left_len - right_len) > limit) {
    return false;
  }
  if (left == right) {
    return true;
  }

  std::vector<int> prev(right_len + 1);
  std::vector<int> curr(right_len + 1, limit + 1);
  for (int j = 0; j <= right_len; ++j) {
    prev[j] = j;
  }

  for (int i = 1; i <= left_len; ++i) {
    std::fill(curr.begin(), curr.end(), limit + 1);
    curr[0] = i;
    const int from = std::max(1, i - limit);
    const int to = std::min(right_len, i + limit);
    int row_min = curr[0];

    for (int j = from; j <= to; ++j) {
      const int cost = left[i - 1] == right[j - 1] ? 0 : 1;
      const int deletion = prev[j] + 1;
      const int insertion = curr[j - 1] + 1;
      const int substitution = prev[j - 1] + cost;
      curr[j] = std::min({deletion, insertion, substitution});
      row_min = std::min(row_min, curr[j]);
    }

    if (row_min > limit) {
      return false;
    }
    prev.swap(curr);
  }

  return prev[right_len] <= limit;
}

inline std::string escapeRubyString(const std::string &text) {
  std::string out;
  out.reserve(text.size() + 8);
  for (char ch : text) {
    switch (ch) {
    case '\\':
      out += "\\\\";
      break;
    case '"':
      out += "\\\"";
      break;
    case '\n':
      out += "\\n";
      break;
    case '\r':
      out += "\\r";
      break;
    case '\t':
      out += "\\t";
      break;
    default:
      out.push_back(ch);
      break;
    }
  }
  return out;
}

inline bool isRubySymbolName(const std::string &key) {
  if (key.empty()) {
    return false;
  }
  if (!(std::isalpha(static_cast<unsigned char>(key[0])) || key[0] == '_')) {
    return false;
  }
  for (std::size_t i = 1; i < key.size(); ++i) {
    const unsigned char ch = static_cast<unsigned char>(key[i]);
    if (!(std::isalnum(ch) || key[i] == '_')) {
      return false;
    }
  }
  return true;
}

inline std::string formatKey(const std::string &key) {
  if (isRubySymbolName(key)) {
    return key + ": ";
  }
  return "\"" + escapeRubyString(key) + "\" => ";
}

inline std::string formatValue(const std::optional<std::string> &value) {
  if (!value.has_value()) {
    return "nil";
  }
  return "\"" + escapeRubyString(*value) + "\"";
}

inline std::string inspectAttrs(const OrderedAttrs &attrs) {
  std::string out = "{";
  bool first = true;
  for (const auto &item : attrs.items) {
    if (!first) {
      out += ", ";
    }
    first = false;
    out += formatKey(item.first);
    out += formatValue(item.second);
  }
  out += "}";
  return out;
}

inline std::vector<std::string> parseCsvLine(const std::string &line) {
  std::vector<std::string> fields;
  std::string field;
  bool in_quotes = false;

  for (std::size_t i = 0; i < line.size(); ++i) {
    const char ch = line[i];
    if (in_quotes) {
      if (ch == '"') {
        if (i + 1 < line.size() && line[i + 1] == '"') {
          field.push_back('"');
          ++i;
        } else {
          in_quotes = false;
        }
      } else {
        field.push_back(ch);
      }
      continue;
    }

    if (ch == '"') {
      in_quotes = true;
      continue;
    }
    if (ch == ',') {
      fields.push_back(field);
      field.clear();
      continue;
    }
    field.push_back(ch);
  }

  fields.push_back(field);
  if (!fields.empty() && !fields.front().empty() && static_cast<unsigned char>(fields.front()[0]) == 0xEF &&
      fields.front().size() >= 3 && static_cast<unsigned char>(fields.front()[1]) == 0xBB &&
      static_cast<unsigned char>(fields.front()[2]) == 0xBF) {
    fields.front().erase(0, 3);
  }
  return fields;
}

inline std::optional<std::string> unescapeLtsvValue(const std::string &text) {
  if (text.empty()) {
    return std::nullopt;
  }

  std::string out;
  out.reserve(text.size());
  for (std::size_t i = 0; i < text.size(); ++i) {
    if (text[i] == '\\' && i + 1 < text.size()) {
      const char next = text[i + 1];
      switch (next) {
      case '\\':
        out.push_back('\\');
        ++i;
        continue;
      case 't':
        out.push_back('\t');
        ++i;
        continue;
      case 'n':
        out.push_back('\n');
        ++i;
        continue;
      case 'r':
        out.push_back('\r');
        ++i;
        continue;
      default:
        break;
      }
    }
    out.push_back(text[i]);
  }
  if (out.empty()) {
    return std::nullopt;
  }
  return out;
}

inline OrderedAttrs parseLtsvLine(const std::string &line) {
  OrderedAttrs attrs;
  std::size_t start = 0;
  while (start <= line.size()) {
    const std::size_t tab = line.find('\t', start);
    const std::string field = line.substr(start, tab == std::string::npos ? std::string::npos : tab - start);
    if (!field.empty()) {
      const std::size_t colon = field.find(':');
      if (colon != std::string::npos) {
        attrs.add(field.substr(0, colon), unescapeLtsvValue(field.substr(colon + 1)));
      }
    }
    if (tab == std::string::npos) {
      break;
    }
    start = tab + 1;
  }
  return attrs;
}

class Parser {
public:
  explicit Parser(std::string text) : text_(std::move(text)) {}

  std::unique_ptr<FilterExpr> parse() {
    auto expr = parseFilter();
    if (pos_ != text_.size()) {
      throw error("unexpected trailing characters");
    }
    return expr;
  }

private:
  std::string text_;
  std::size_t pos_ = 0;

  std::unique_ptr<FilterExpr> parseFilter() {
    expect('(');
    const char current = peek();
    if (current == '\0') {
      throw error("parenthesis mismatch");
    }

    if (current == '&') {
      ++pos_;
      auto children = parseSubfilters();
      if (children.empty()) {
        throw error("and operator requires filters");
      }
      expect(')');
      return std::make_unique<FilterExpr>(FilterAnd{std::move(children)});
    }

    if (current == '|') {
      ++pos_;
      auto children = parseSubfilters();
      if (children.empty()) {
        throw error("or operator requires filters");
      }
      expect(')');
      return std::make_unique<FilterExpr>(FilterOr{std::move(children)});
    }

    if (current == '!') {
      ++pos_;
      auto child = parseFilter();
      if (peek() == '(') {
        throw error("not operator has more than one filter");
      }
      expect(')');
      return std::make_unique<FilterExpr>(FilterNot{std::move(child)});
    }

    auto item = parseItem();
    expect(')');
    return std::make_unique<FilterExpr>(std::move(item));
  }

  std::vector<std::unique_ptr<FilterExpr>> parseSubfilters() {
    std::vector<std::unique_ptr<FilterExpr>> children;
    while (peek() == '(') {
      children.push_back(parseFilter());
    }
    return children;
  }

  FilterItem parseItem() {
    const std::size_t start = pos_;
    while (true) {
      const char current = peek();
      if (current == '\0') {
        throw error("parenthesis mismatch");
      }
      if (current == ')') {
        break;
      }
      ++pos_;
    }

    const std::string item = text_.substr(start, pos_ - start);
    const std::size_t op_pos = item.find_first_of("~=><");
    if (op_pos == std::string::npos || op_pos == 0 || op_pos + 1 >= item.size()) {
      throw error("error in item syntax", start);
    }

    std::string attr;
    FilterItem::Op op;
    std::string raw_value;

    switch (item[op_pos]) {
    case '=':
      attr = item.substr(0, op_pos);
      op = FilterItem::Op::Eq;
      raw_value = item.substr(op_pos + 1);
      break;
    case '~':
      if (item[op_pos + 1] != '=') {
        throw error("error in item syntax", start);
      }
      attr = item.substr(0, op_pos);
      op = FilterItem::Op::Approx;
      raw_value = item.substr(op_pos + 2);
      break;
    case '>':
      if (item[op_pos + 1] != '=') {
        throw error("error in item syntax", start);
      }
      attr = item.substr(0, op_pos);
      op = FilterItem::Op::Ge;
      raw_value = item.substr(op_pos + 2);
      break;
    case '<':
      if (item[op_pos + 1] != '=') {
        throw error("error in item syntax", start);
      }
      attr = item.substr(0, op_pos);
      op = FilterItem::Op::Le;
      raw_value = item.substr(op_pos + 2);
      break;
    default:
      throw error("error in item syntax", start);
    }

    auto [value, matcher] = parseItemValue(raw_value, start);
    return FilterItem{std::move(attr), op, std::move(value), std::move(matcher)};
  }

  char peek() const {
    if (pos_ >= text_.size()) {
      return '\0';
    }
    return text_[pos_];
  }

  void expect(char expected) {
    const char actual = peek();
    if (actual != expected) {
      if (actual == '\0') {
        std::ostringstream oss;
        oss << "expected " << std::quoted(std::string(1, expected)) << ", found EOF";
        throw error(oss.str());
      }
      std::ostringstream oss;
      oss << "expected " << std::quoted(std::string(1, expected)) << ", found " << std::quoted(std::string(1, actual));
      throw error(oss.str());
    }
    ++pos_;
  }

  LdapFilterError error(const std::string &message, std::optional<std::size_t> position = std::nullopt) const {
    std::ostringstream oss;
    oss << message << " at position " << position.value_or(pos_);
    return LdapFilterError(oss.str());
  }
};

inline std::unique_ptr<FilterExpr> parseFilter(const std::string &text) {
  return Parser{text}.parse();
}

inline std::string shellQuote(const std::string &text) {
  std::string out = "'";
  for (char ch : text) {
    if (ch == '\'') {
      out += "'\"'\"'";
    } else {
      out.push_back(ch);
    }
  }
  out.push_back('\'');
  return out;
}

template <typename Callback>
inline void withInputLines(const std::string &inputPath, Callback &&callback) {
  if (inputPath.size() >= 3 && inputPath.ends_with(".xz")) {
    const std::string cmd = "xz -dc " + shellQuote(inputPath);
    FILE *pipe = popen(cmd.c_str(), "r");
    if (pipe == nullptr) {
      throw std::runtime_error("failed to open xz process for " + inputPath);
    }

    char *line = nullptr;
    std::size_t cap = 0;
    while (true) {
      const ssize_t len = ::getline(&line, &cap, pipe);
      if (len == -1) {
        break;
      }
      std::string text(line, static_cast<std::size_t>(len));
      callback(text);
    }
    std::free(line);
    const int status = pclose(pipe);
    if (status != 0) {
      throw std::runtime_error("xz failed for " + inputPath);
    }
    return;
  }

  std::ifstream input(inputPath);
  if (!input.is_open()) {
    throw std::runtime_error("failed to open " + inputPath);
  }

  std::string line;
  while (std::getline(input, line)) {
    callback(line);
  }
}

inline std::string detectFormat(const std::string &inputPath) {
  const auto base = std::filesystem::path(inputPath).filename().string();
  if (base.ends_with(".csv") || base.ends_with(".csv.xz")) {
    return "csv";
  }
  if (base.ends_with(".ltsv") || base.ends_with(".ltsv.xz")) {
    return "ltsv";
  }
  return "csv";
}

inline std::string selectFormat(const std::string &format, const std::string &inputPath) {
  if (format != "auto") {
    return format;
  }
  return detectFormat(inputPath);
}

inline void eachCsvAttrs(const std::string &inputPath, const std::function<void(const OrderedAttrs &)> &callback) {
  bool first_line = true;
  std::vector<std::string> headers;

  withInputLines(inputPath, [&](const std::string &raw_line) {
    std::string line = raw_line;
    while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) {
      line.pop_back();
    }
    if (line.empty()) {
      return;
    }

    const auto fields = parseCsvLine(line);
    if (first_line) {
      headers = fields;
      first_line = false;
      return;
    }

    OrderedAttrs attrs;
    for (std::size_t i = 0; i < headers.size(); ++i) {
      const std::string value = i < fields.size() ? fields[i] : "";
      attrs.add(headers[i], value);
    }
    callback(attrs);
  });
}

inline void eachLtsvAttrs(const std::string &inputPath, const std::function<void(const OrderedAttrs &)> &callback) {
  withInputLines(inputPath, [&](const std::string &raw_line) {
    std::string line = raw_line;
    while (!line.empty() && (line.back() == '\n' || line.back() == '\r')) {
      line.pop_back();
    }
    if (line.empty()) {
      return;
    }
    callback(parseLtsvLine(line));
  });
}

inline int64_t monotonicNs() {
  using namespace std::chrono;
  return duration_cast<nanoseconds>(steady_clock::now().time_since_epoch()).count();
}

inline std::string phaseLine(const std::string &phase, int64_t startNs, int64_t nowNs) {
  const int64_t elapsedNs = nowNs - startNs;
  std::ostringstream oss;
  oss << "phase=" << phase << " t=" << elapsedNs << " elapsed_ns=" << elapsedNs;
  return oss.str();
}

inline int runCli(const std::vector<std::string> &argv, std::ostream &stdoutStream, std::ostream &stderrStream) {
  try {
    std::string filter;
    std::string inputPath;
    std::string format = "auto";
    std::vector<std::string> positionals;

    for (std::size_t i = 0; i < argv.size(); ++i) {
      const std::string &arg = argv[i];
      if (arg == "--help" || arg == "-h") {
        stdoutStream << "Usage: ldap_filter [options] FILTER INPUT\n";
        return 0;
      }
      if (arg == "--jit" || arg == "--no-jit") {
        continue;
      }
      if (arg == "--filter" || arg == "--input" || arg == "--format") {
        if (i + 1 >= argv.size()) {
          throw std::invalid_argument("missing value for " + arg);
        }
        const std::string value = argv[++i];
        if (arg == "--filter") {
          filter = value;
        } else if (arg == "--input") {
          inputPath = value;
        } else {
          format = value;
        }
        continue;
      }
      if (arg.rfind("--filter=", 0) == 0) {
        filter = arg.substr(9);
        continue;
      }
      if (arg.rfind("--input=", 0) == 0) {
        inputPath = arg.substr(8);
        continue;
      }
      if (arg.rfind("--format=", 0) == 0) {
        format = arg.substr(9);
        continue;
      }
      if (arg.rfind("--", 0) == 0) {
        throw std::invalid_argument("unsupported option: " + arg);
      }
      positionals.push_back(arg);
    }

    if (filter.empty() && !positionals.empty()) {
      filter = positionals[0];
    }
    if (inputPath.empty() && positionals.size() >= 2) {
      inputPath = positionals[1];
    }
    if (filter.empty() || inputPath.empty()) {
      throw std::invalid_argument("filter and input path are required");
    }

    const int64_t startNs = monotonicNs();
    stderrStream << phaseLine("boot", startNs, monotonicNs()) << '\n';

    const std::string selectedFormat = selectFormat(format, inputPath);
    auto expr = parseFilter(filter);

    stderrStream << phaseLine("ready", startNs, monotonicNs()) << '\n';

    if (selectedFormat == "csv") {
      eachCsvAttrs(inputPath, [&](const OrderedAttrs &attrs) {
        if (expr->evaluate(attrs)) {
          stdoutStream << inspectAttrs(attrs) << '\n';
        }
      });
    } else if (selectedFormat == "ltsv") {
      eachLtsvAttrs(inputPath, [&](const OrderedAttrs &attrs) {
        if (expr->evaluate(attrs)) {
          stdoutStream << inspectAttrs(attrs) << '\n';
        }
      });
    } else {
      throw std::invalid_argument("unsupported format: " + selectedFormat);
    }

    stderrStream << phaseLine("done", startNs, monotonicNs()) << '\n';
    return 0;
  } catch (const std::exception &error) {
    stderrStream << error.what() << '\n';
    return 1;
  }
}

inline int runCli(const std::vector<std::string> &argv) {
  return runCli(argv, std::cout, std::cerr);
}

} // namespace ldf
