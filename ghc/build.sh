#!/usr/bin/env bash
set -eu -o pipefail
# mise の GHC 8.10.7 にバンドルされた C コンパイラを PATH に追加
GHC_BIN="$(ghc --print-libdir)/../bin"
export PATH="$GHC_BIN:$PATH"
mkdir -p bin
ghc -O2 -isrc -outputdir /tmp/ghc-ldf-build -o bin/ldap_filter app/Main.hs
