#!/usr/bin/env bash
set -euo pipefail

tmp="$(mktemp /tmp/ldf-csharp-aot-XXXX.ltsv)"
trap 'rm -f "$tmp"' EXIT

printf 'host:example.com\tpass:true\nhost:other\tpass:false\n' > "$tmp"
"./bin/Release/net10.0/linux-x64/publish/LdapFilter.Aot" --format ltsv "(host=example.com)" "$tmp"

