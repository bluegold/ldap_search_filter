#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import io
import json
import lzma
import re
import sys
import time
from dataclasses import dataclass, field
from typing import Iterable, Optional, TextIO


_MISSING = object()
_ITEM_RE = re.compile(r"\A([^~=><]+)(~=|>=|<=|=)(.+)\Z")
_SYMBOL_NAME_RE = re.compile(r"\A[A-Za-z_][A-Za-z0-9_]*\Z")


class LdapFilterError(Exception):
    pass


@dataclass
class OrderedAttrs:
    items: list[tuple[str, Optional[str]]] = field(default_factory=list)

    def add(self, key: str, value: Optional[str]) -> None:
        self.items.append((key, value))

    def contains(self, key: str) -> bool:
        return any(candidate == key for candidate, _ in self.items)

    def get(self, key: str):
        for candidate, value in self.items:
            if candidate == key:
                return value
        return _MISSING


@dataclass(frozen=True)
class ItemMatcher:
    kind: str
    parts: tuple[str, ...] = ()
    leading_star: bool = False
    trailing_star: bool = False


class FilterExpr:
    def evaluate(self, attrs: OrderedAttrs) -> bool:
        raise NotImplementedError


@dataclass(frozen=True)
class FilterAnd(FilterExpr):
    children: tuple[FilterExpr, ...]

    def evaluate(self, attrs: OrderedAttrs) -> bool:
        return all(child.evaluate(attrs) for child in self.children)


@dataclass(frozen=True)
class FilterOr(FilterExpr):
    children: tuple[FilterExpr, ...]

    def evaluate(self, attrs: OrderedAttrs) -> bool:
        return any(child.evaluate(attrs) for child in self.children)


@dataclass(frozen=True)
class FilterNot(FilterExpr):
    child: FilterExpr

    def evaluate(self, attrs: OrderedAttrs) -> bool:
        return not self.child.evaluate(attrs)


@dataclass(frozen=True)
class FilterItem(FilterExpr):
    attr: str
    op: str
    value: str
    matcher: ItemMatcher

    def evaluate(self, attrs: OrderedAttrs) -> bool:
        actual = attrs.get(self.attr)

        if self.op == "=":
            if self.matcher.kind == "presence":
                return attrs.contains(self.attr)
            if actual is _MISSING:
                return False
            if self.matcher.kind == "wildcard":
                return isinstance(actual, str) and wildcard_matches(
                    self.matcher.parts,
                    self.matcher.leading_star,
                    self.matcher.trailing_star,
                    actual,
                )
            return actual == self.value

        if actual is _MISSING or actual is None:
            return False

        if self.op == "~=":
            return levenshtein_distance_lte(str(actual), self.value, 2)
        if self.op == ">=":
            return str(actual) >= self.value
        if self.op == "<=":
            return str(actual) <= self.value
        raise LdapFilterError(f"unsupported operator: {self.op}")


class FilterParser:
    def __init__(self, text: str):
        self.text = text
        self.pos = 0

    def parse(self) -> FilterExpr:
        expr = self._parse_filter()
        if self.pos != len(self.text):
            raise self._error("unexpected trailing characters")
        return expr

    def _parse_filter(self) -> FilterExpr:
        self._expect("(")
        current = self._peek()
        if current is None:
            raise self._error("parenthesis mismatch")

        if current == "&":
            self.pos += 1
            children = self._parse_subfilters()
            if not children:
                raise self._error("and operator requires filters")
            self._expect(")")
            return FilterAnd(tuple(children))

        if current == "|":
            self.pos += 1
            children = self._parse_subfilters()
            if not children:
                raise self._error("or operator requires filters")
            self._expect(")")
            return FilterOr(tuple(children))

        if current == "!":
            self.pos += 1
            child = self._parse_filter()
            if self._peek() == "(":
                raise self._error("not operator has more than one filter")
            self._expect(")")
            return FilterNot(child)

        item = self._parse_item()
        self._expect(")")
        return item

    def _parse_subfilters(self) -> list[FilterExpr]:
        children: list[FilterExpr] = []
        while self._peek() == "(":
            children.append(self._parse_filter())
        return children

    def _parse_item(self) -> FilterItem:
        start = self.pos
        while True:
            current = self._peek()
            if current is None:
                raise self._error("parenthesis mismatch")
            if current == ")":
                break
            self.pos += 1

        item = self.text[start:self.pos]
        match = _ITEM_RE.match(item)
        if match is None:
            raise self._error("error in item syntax", start)

        attr = match.group(1)
        op = match.group(2)
        raw_value = match.group(3)
        value, matcher = parse_item_value(raw_value, start)
        return FilterItem(attr=attr, op=op, value=value, matcher=matcher)

    def _peek(self) -> Optional[str]:
        if self.pos >= len(self.text):
            return None
        return self.text[self.pos]

    def _expect(self, expected: str) -> None:
        actual = self._peek()
        if actual != expected:
            if actual is None:
                raise self._error(f"expected {expected!r}, found EOF")
            raise self._error(f"expected {expected!r}, found {actual!r}")
        self.pos += 1

    def _error(self, message: str, position: Optional[int] = None) -> LdapFilterError:
        if position is None:
            position = self.pos
        return LdapFilterError(f"{message} at position {position}")


def parse_filter(text: str) -> FilterExpr:
    parser = FilterParser(text)
    return parser.parse()


def parse_item_value(raw: str, position: int) -> tuple[str, ItemMatcher]:
    if raw == "*":
        return "*", ItemMatcher(kind="presence")

    decoded: list[str] = []
    segments: list[str] = []
    current: list[str] = []
    saw_wildcard = False
    i = 0

    while i < len(raw):
        ch = raw[i]
        if ch == "\\":
            if i + 2 >= len(raw):
                raise LdapFilterError(f"incomplete escape sequence at position {position}")
            decoded_char = decode_hex_escape(raw[i + 1], raw[i + 2], position)
            decoded.append(decoded_char)
            current.append(decoded_char)
            i += 3
            continue
        if ch == "*":
            saw_wildcard = True
            decoded.append("*")
            segments.append("".join(current))
            current = []
            i += 1
            continue

        decoded.append(ch)
        current.append(ch)
        i += 1

    decoded_text = "".join(decoded)
    if not saw_wildcard:
        return decoded_text, ItemMatcher(kind="exact")

    segments.append("".join(current))
    return decoded_text, ItemMatcher(
        kind="wildcard",
        parts=tuple(segments),
        leading_star=raw.startswith("*"),
        trailing_star=raw.endswith("*"),
    )


def decode_hex_escape(high: str, low: str, position: int) -> str:
    try:
        return chr(int(high + low, 16))
    except ValueError as exc:
        raise LdapFilterError(f"invalid escape sequence: \\{high}{low} at position {position}") from exc


def wildcard_matches(parts: Iterable[str], leading_star: bool, trailing_star: bool, actual: str) -> bool:
    non_empty = [part for part in parts if part]
    if not non_empty:
        return True

    position = 0
    for index, part in enumerate(non_empty):
        is_first = index == 0
        is_last = index == len(non_empty) - 1

        if is_first and not leading_star:
            if not actual[position:].startswith(part):
                return False
            position += len(part)
            continue

        if is_last and not trailing_star:
            return actual[position:].endswith(part)

        found = actual.find(part, position)
        if found < 0:
            return False
        position = found + len(part)

    return True


def levenshtein_distance_lte(a: str, b: str, max_distance: int) -> bool:
    a_chars = list(a)
    b_chars = list(b)
    if abs(len(a_chars) - len(b_chars)) > max_distance:
        return False

    prev = list(range(len(b_chars) + 1))
    curr = [0] * (len(b_chars) + 1)

    for i, a_ch in enumerate(a_chars):
        curr[0] = i + 1
        row_min = curr[0]

        for j, b_ch in enumerate(b_chars):
            cost = 0 if a_ch == b_ch else 1
            delete = prev[j + 1] + 1
            insert = curr[j] + 1
            substitute = prev[j] + cost
            value = min(delete, insert, substitute)
            curr[j + 1] = value
            row_min = min(row_min, value)

        if row_min > max_distance:
            return False

        prev, curr = curr, prev

    return prev[-1] <= max_distance


def escape_ruby_string(text: str) -> str:
    return json.dumps(text)[1:-1]


def format_key(key: str) -> str:
    if _SYMBOL_NAME_RE.match(key):
        return f"{key}: "
    return f"{json.dumps(key)} => "


def format_value(value: Optional[str]) -> str:
    if value is None:
        return "nil"
    return f"\"{escape_ruby_string(str(value))}\""


def inspect_attrs(attrs: OrderedAttrs) -> str:
    parts = [f"{format_key(key)}{format_value(value)}" for key, value in attrs.items]
    return "{" + ", ".join(parts) + "}"


def parse_csv_header(line: str) -> list[str]:
    return parse_csv_line(line.lstrip("\ufeff"))


def parse_csv_line(line: str) -> list[str]:
    try:
        reader = csv.reader([line])
        return next(reader)
    except (csv.Error, StopIteration):
        return [line]


def row_to_attrs(headers: list[str], row: list[str]) -> OrderedAttrs:
    attrs = OrderedAttrs()
    for index, header in enumerate(headers):
        value = row[index] if index < len(row) else ""
        attrs.add(header, value)
    return attrs


def unescape_ltsv_value(value: str) -> Optional[str]:
    if value == "":
        return None

    out: list[str] = []
    i = 0
    while i < len(value):
        ch = value[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue

        if i + 1 >= len(value):
            out.append("\\")
            break

        escaped = value[i + 1]
        if escaped == "r":
            out.append("\r")
        elif escaped == "n":
            out.append("\n")
        elif escaped == "t":
            out.append("\t")
        elif escaped == "\\":
            out.append("\\")
        else:
            out.append("\\")
            out.append(escaped)
        i += 2

    result = "".join(out)
    return None if result == "" else result


def parse_ltsv_line(line: str) -> OrderedAttrs:
    attrs = OrderedAttrs()
    if line == "":
        return attrs

    for entry in line.split("\t"):
        if ":" not in entry:
            continue
        key, value = entry.split(":", 1)
        attrs.add(key, unescape_ltsv_value(value))
    return attrs


def detect_format(input_path: str) -> str:
    lower = input_path.lower()
    if lower.endswith(".csv") or lower.endswith(".csv.xz"):
        return "csv"
    if lower.endswith(".ltsv") or lower.endswith(".ltsv.xz"):
        return "ltsv"
    return "ltsv"


def phase_line(phase: str, started_ns: int) -> str:
    elapsed_ns = time.perf_counter_ns() - started_ns
    return f"phase={phase} t={elapsed_ns} elapsed_ns={elapsed_ns}"


def open_input(path: str):
    if path.lower().endswith(".xz"):
        return lzma.open(path, "rt", encoding="utf-8", newline="")
    return open(path, "rt", encoding="utf-8", newline="")


def run_with_io(argv: list[str], stdout: TextIO = sys.stdout, stderr: TextIO = sys.stderr) -> int:
    started_ns = time.perf_counter_ns()
    stderr.write(phase_line("boot", started_ns) + "\n")

    parser = argparse.ArgumentParser(prog="ldap_filter.py")
    parser.add_argument("--format", choices=["auto", "csv", "ltsv"], default="auto")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--jit", action="store_true")
    group.add_argument("--no-jit", action="store_true")
    parser.add_argument("filter")
    parser.add_argument("input")

    try:
        args = parser.parse_args(argv)
        format_kind = args.format if args.format != "auto" else detect_format(args.input)
        expr = parse_filter(args.filter)

        with open_input(args.input) as handle:
            if format_kind == "csv":
                header_line = handle.readline()
                headers = parse_csv_header(header_line.rstrip("\r\n")) if header_line else []
            else:
                headers = []

            stderr.write(phase_line("ready", started_ns) + "\n")

            if format_kind == "csv":
                for line in handle:
                    row = parse_csv_line(line.rstrip("\r\n"))
                    attrs = row_to_attrs(headers, row)
                    if expr.evaluate(attrs):
                        stdout.write(inspect_attrs(attrs) + "\n")
            else:
                for line in handle:
                    attrs = parse_ltsv_line(line.rstrip("\r\n"))
                    if expr.evaluate(attrs):
                        stdout.write(inspect_attrs(attrs) + "\n")

        stderr.write(phase_line("done", started_ns) + "\n")
        return 0
    except LdapFilterError as exc:
        stderr.write(str(exc) + "\n")
        return 1
    except OSError as exc:
        stderr.write(str(exc) + "\n")
        return 1


def main(argv: Optional[list[str]] = None) -> int:
    if argv is None:
        argv = sys.argv[1:]
    return run_with_io(argv)


if __name__ == "__main__":
    raise SystemExit(main())
