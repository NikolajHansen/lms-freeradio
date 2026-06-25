#!/usr/bin/env bash
# Run FreeRadio plugin tests
set -euo pipefail

VENDOR=/home/nikolaj/workspace/logitech/slimserver-vendor/CPAN/build/arch/5.38/x86_64-linux-gnu-thread-multi
REPO="$(cd "$(dirname "$0")/.." && pwd)"

cd "$REPO"

PERL_LIBS="-I $VENDOR -I t/lib -I Plugins"

PASS=0; FAIL=0
for t in t/0*.t; do
    if perl $PERL_LIBS "$t" 2>&1; then
        PASS=$((PASS+1))
    else
        FAIL=$((FAIL+1))
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
