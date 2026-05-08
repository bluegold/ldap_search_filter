#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

BINARY=./ldap_filter
if [[ ! -x "$BINARY" ]]; then
  echo "Binary not found — build first (just test-sbcl or bench.yml build step)"
  exit 1
fi

TMPFILE=$(mktemp /tmp/ldf-smoke-XXXXXX.ltsv)
trap 'rm -f "$TMPFILE"' EXIT

printf 'host:example.com\tstatus:200\n' > "$TMPFILE"
printf 'host:example.org\tstatus:404\n' >> "$TMPFILE"

run() {
  local desc=$1; shift
  local expected=$1; shift
  local result
  result=$("$BINARY" "$@" 2>/dev/null)
  if [[ "$result" == "$expected" ]]; then
    echo "OK: $desc"
  else
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  got:      $result"
    exit 1
  fi
}

run "ltsv equality" \
    '{host: "example.com", status: "200"}' \
    --format ltsv '(host=example.com)' "$TMPFILE"

run "ltsv AND" \
    '{host: "example.com", status: "200"}' \
    --format ltsv '(&(host=example.com)(status=200))' "$TMPFILE"

run "ltsv OR" \
    '{host: "example.com", status: "200"}
{host: "example.org", status: "404"}' \
    --format ltsv '(|(host=example.com)(host=example.org))' "$TMPFILE"

run "ltsv NOT" \
    '{host: "example.com", status: "200"}' \
    --format ltsv '(!(status=404))' "$TMPFILE"

run "ltsv trailing wildcard" \
    '{host: "example.com", status: "200"}' \
    --format ltsv '(host=*.com)' "$TMPFILE"

run "ltsv presence" \
    '{host: "example.com", status: "200"}
{host: "example.org", status: "404"}' \
    --format ltsv '(host=*)' "$TMPFILE"

echo "All smoke tests passed."
