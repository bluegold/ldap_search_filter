#!/usr/bin/env bash
set -eu -o pipefail
GHC_BIN="$(ghc --print-libdir)/../bin"
export PATH="$GHC_BIN:$PATH"
ghc -O2 -isrc -outputdir /tmp/ghc-ldf-test -o /tmp/ghc-ldf-spec test/Spec.hs 2>/dev/null
/tmp/ghc-ldf-spec 2>/dev/null
