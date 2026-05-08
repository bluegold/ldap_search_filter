#!/usr/bin/env bash
set -eu -o pipefail
cd "$(dirname "$0")"

BINARY="./bin/ldap_filter"
if [[ ! -x "$BINARY" ]]; then
  echo "Binary not found: $BINARY — run build.sh first" >&2
  exit 1
fi

TMPFILE=$(mktemp /tmp/ghc-smoke-XXXXXX.ltsv)
trap 'rm -f "$TMPFILE"' EXIT

cat > "$TMPFILE" <<'EOF'
host:example.com	status:200	method:GET
host:other.com	status:404	method:GET
host:www.example.com	status:200	method:POST
EOF

ok() { echo "OK: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# equality
out=$("$BINARY" --format ltsv '(host=example.com)' "$TMPFILE" 2>/dev/null)
echo "$out" | grep -q '"example.com"' && ok "ltsv equality" || fail "ltsv equality"

# AND
out=$("$BINARY" --format ltsv '(&(host=example.com)(status=200))' "$TMPFILE" 2>/dev/null)
[[ $(echo "$out" | wc -l) -eq 1 ]] && ok "ltsv AND" || fail "ltsv AND"

# OR
out=$("$BINARY" --format ltsv '(|(host=example.com)(status=404))' "$TMPFILE" 2>/dev/null)
[[ $(echo "$out" | wc -l) -eq 2 ]] && ok "ltsv OR" || fail "ltsv OR"

# NOT
out=$("$BINARY" --format ltsv '(!(status=200))' "$TMPFILE" 2>/dev/null)
echo "$out" | grep -q '"404"' && ok "ltsv NOT" || fail "ltsv NOT"

# trailing wildcard
out=$("$BINARY" --format ltsv '(host=*.example.com)' "$TMPFILE" 2>/dev/null)
[[ $(echo "$out" | wc -l) -eq 1 ]] && ok "ltsv trailing wildcard" || fail "ltsv trailing wildcard"

# presence
out=$("$BINARY" --format ltsv '(method=*)' "$TMPFILE" 2>/dev/null)
[[ $(echo "$out" | wc -l) -eq 3 ]] && ok "ltsv presence" || fail "ltsv presence"

echo "All smoke tests passed."
