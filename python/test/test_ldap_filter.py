import io
import lzma
import tempfile
import unittest
from pathlib import Path

import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from ldap_filter import (  # noqa: E402
    OrderedAttrs,
    detect_format,
    inspect_attrs,
    parse_filter,
    parse_ltsv_line,
    run_with_io,
)


class LdapFilterTest(unittest.TestCase):
    def test_parse_and_evaluate_filter(self):
        expr = parse_filter("(&(host=example.com)(pass=true))")
        attrs = OrderedAttrs([("host", "example.com"), ("pass", "true")])
        self.assertTrue(expr.evaluate(attrs))
        self.assertFalse(expr.evaluate(OrderedAttrs([("host", "example.com")])))

    def test_parse_wildcard_and_approx(self):
        wildcard = parse_filter("(host=exa*ple.com)")
        approx = parse_filter("(cn~=abcd)")
        attrs = OrderedAttrs([("host", "example.com"), ("cn", "abce")])
        self.assertTrue(wildcard.evaluate(attrs))
        self.assertTrue(approx.evaluate(attrs))

    def test_inspect_attrs_formats_ruby_like_hashes(self):
        rendered = inspect_attrs(
            OrderedAttrs(
                [
                    ("host", "example.com"),
                    ("http/2", "true"),
                    ("empty", None),
                ]
            )
        )
        self.assertEqual('{host: "example.com", "http/2" => "true", empty: nil}', rendered)

    def test_parse_ltsv_unescapes_values(self):
        attrs = parse_ltsv_line("host:example\\texample\tcomment:line\\nnext\tempty:")
        self.assertEqual("example\texample", attrs.get("host"))
        self.assertEqual("line\nnext", attrs.get("comment"))
        self.assertIsNone(attrs.get("empty"))

    def test_cli_ltsv_and_csv_emit_phases(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = Path(tmpdir)
            ltsv_path = tmp / "sample.ltsv"
            csv_path = tmp / "sample.csv"
            xz_path = tmp / "sample.ltsv.xz"

            ltsv_path.write_text("host:example.com\tpass:true\nhost:other\tpass:false\n", encoding="utf-8")
            csv_path.write_text("host,pass\nexample.com,true\nother,false\n", encoding="utf-8")
            with lzma.open(xz_path, "wt", encoding="utf-8") as handle:
                handle.write("host:example.com\tpass:true\n")

            ltsv_stdout = io.StringIO()
            ltsv_stderr = io.StringIO()
            code = run_with_io(["--format", "ltsv", "(host=example.com)", str(ltsv_path)], ltsv_stdout, ltsv_stderr)
            self.assertEqual(0, code)
            self.assertEqual('{host: "example.com", pass: "true"}\n', ltsv_stdout.getvalue())
            self.assertIn("phase=boot", ltsv_stderr.getvalue())
            self.assertIn("phase=ready", ltsv_stderr.getvalue())
            self.assertIn("phase=done", ltsv_stderr.getvalue())

            csv_stdout = io.StringIO()
            csv_stderr = io.StringIO()
            code = run_with_io(["--format", "csv", "(host=example.com)", str(csv_path)], csv_stdout, csv_stderr)
            self.assertEqual(0, code)
            self.assertEqual('{host: "example.com", pass: "true"}\n', csv_stdout.getvalue())
            self.assertIn("phase=boot", csv_stderr.getvalue())
            self.assertIn("phase=ready", csv_stderr.getvalue())
            self.assertIn("phase=done", csv_stderr.getvalue())

            xz_stdout = io.StringIO()
            xz_stderr = io.StringIO()
            code = run_with_io(["--format", "auto", "(host=example.com)", str(xz_path)], xz_stdout, xz_stderr)
            self.assertEqual(0, code)
            self.assertEqual('{host: "example.com", pass: "true"}\n', xz_stdout.getvalue())
            self.assertIn("phase=boot", xz_stderr.getvalue())
            self.assertIn("phase=ready", xz_stderr.getvalue())
            self.assertIn("phase=done", xz_stderr.getvalue())

    def test_detect_format(self):
        self.assertEqual("csv", detect_format("data.csv.xz"))
        self.assertEqual("ltsv", detect_format("data.ltsv"))


if __name__ == "__main__":
    unittest.main()
