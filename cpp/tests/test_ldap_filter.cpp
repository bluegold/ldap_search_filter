#include "../ldap_filter.hpp"

#include <cassert>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>

using namespace ldf;

static void check(bool condition, const std::string &message) {
  if (!condition) {
    throw std::runtime_error(message);
  }
}

static void checkEq(const std::string &expected, const std::string &actual, const std::string &message) {
  if (expected != actual) {
    std::ostringstream oss;
    oss << message << "\nexpected: " << expected << "\nactual:   " << actual;
    throw std::runtime_error(oss.str());
  }
}

static std::filesystem::path writeTempFile(const std::string &suffix, const std::string &content) {
  auto dir = std::filesystem::temp_directory_path();
  auto path = dir / std::filesystem::path("ldf-cpp-" + std::to_string(std::rand()) + suffix);
  std::ofstream out(path);
  out << content;
  return path;
}

static std::string maybeMakeXz(const std::filesystem::path &path) {
  if (std::system("command -v xz >/dev/null 2>&1") != 0) {
    return {};
  }

  auto xzPath = path;
  xzPath += ".xz";
  std::ostringstream cmd;
  cmd << "xz -c " << shellQuote(path.string()) << " > " << shellQuote(xzPath.string());
  if (std::system(cmd.str().c_str()) != 0) {
    return {};
  }
  return xzPath.string();
}

static void testInspectAttrs() {
  OrderedAttrs attrs;
  attrs.add("host", std::string("www.example.com"));
  attrs.add("http/2", std::string("true"));
  checkEq("{host: \"www.example.com\", \"http/2\" => \"true\"}", inspectAttrs(attrs), "inspectAttrs mismatch");
}

static void testParserAndEvaluator() {
  OrderedAttrs attrs;
  attrs.add("host", std::string("www.example.com"));
  attrs.add("status", std::string("200"));

  check(parseFilter("(host=*)")->evaluate(attrs), "presence filter failed");
  check(parseFilter("(host=www.example.com)")->evaluate(attrs), "exact filter failed");
  check(parseFilter("(&(host=www.example.com)(status>=200))")->evaluate(attrs), "compound filter failed");
  check(!parseFilter("(!(host=www.example.com))")->evaluate(attrs), "not filter failed");
}

static void testLtsvParsing() {
  auto attrs = parseLtsvLine("path:line\\t1\tmessage:hello\\nworld\tquoted:backslash\\\\end\tempty:");
  checkEq("{path: \"line\\t1\", message: \"hello\\nworld\", quoted: \"backslash\\\\end\", empty: nil}", inspectAttrs(attrs),
          "LTSV parse mismatch");
}

static void testCliCsvAndLtsv() {
  auto csv = writeTempFile(".csv", "host,status\nwww.example.com,200\nother.example.com,404\n");
  auto ltsv = writeTempFile(".ltsv", "host:www.example.com\tstatus:200\nhost:other.example.com\tstatus:404\n");

  {
    std::ostringstream out;
    std::ostringstream err;
    const int code = runCli({"--filter", "(host=www.example.com)", "--input", csv.string(), "--format", "csv"}, out, err);
    check(code == 0, "CSV CLI exit code");
    checkEq("{host: \"www.example.com\", status: \"200\"}\n", out.str(), "CSV stdout");
    check(err.str().find("phase=boot") != std::string::npos, "CSV stderr boot");
    check(err.str().find("phase=ready") != std::string::npos, "CSV stderr ready");
    check(err.str().find("phase=done") != std::string::npos, "CSV stderr done");
  }

  {
    std::ostringstream out;
    std::ostringstream err;
    const int code = runCli({"--filter", "(host=www.example.com)", "--input", ltsv.string(), "--format", "ltsv"}, out, err);
    check(code == 0, "LTSV CLI exit code");
    checkEq("{host: \"www.example.com\", status: \"200\"}\n", out.str(), "LTSV stdout");
    check(err.str().find("phase=boot") != std::string::npos, "LTSV stderr boot");
    check(err.str().find("phase=ready") != std::string::npos, "LTSV stderr ready");
    check(err.str().find("phase=done") != std::string::npos, "LTSV stderr done");
  }

  const std::string xzCsv = maybeMakeXz(csv);
  if (!xzCsv.empty()) {
    std::ostringstream out;
    std::ostringstream err;
    const int code = runCli({"--filter", "(host=www.example.com)", "--input", xzCsv}, out, err);
    check(code == 0, "XZ CSV CLI exit code");
    checkEq("{host: \"www.example.com\", status: \"200\"}\n", out.str(), "XZ CSV stdout");
    check(err.str().find("phase=done") != std::string::npos, "XZ CSV stderr done");
  }
}

int main() {
  std::srand(1);
  testInspectAttrs();
  testParserAndEvaluator();
  testLtsvParsing();
  testCliCsvAndLtsv();
  std::cout << "OK\n";
  return 0;
}
