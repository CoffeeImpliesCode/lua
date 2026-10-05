#!/usr/bin/env bash
# Source-integrity check for the Lua SDK.
#
# Three questions, all answerable without a compiler:
#
#   1. Do the 75 upstream files still hash to the digests UPSTREAM.sha256 records?
#   2. Is the native file set exactly that set -- no missing, extra or renamed
#      file under src/ or doc/?  A plain checksum run cannot see an addition.
#   3. Is the preserved upstream README still byte-identical to the imported
#      README, and is Lua's own MIT grant still where the records say it is?
#
# This is a provenance gate, not a build gate. Nothing here compiles, links or
# runs a target binary; it is the check that an edit to the canonical native
# source cannot pass as a routine change.
#
# Usage: tools/check-provenance.sh   (run from anywhere in the repository)
#
# SPDX-License-Identifier: MIT

set -euo pipefail

cd "$(dirname "$0")/.."

fail() {
    echo "$1" >&2
    exit 1
}

# 1. Bytes.
sha256sum -c --quiet UPSTREAM.sha256 || fail "an upstream file no longer matches UPSTREAM.sha256"
echo "all 75 upstream files match UPSTREAM.sha256"

# 2. File set.
expected_tree=$(awk '/^[0-9a-f]{64}  / { print $2 }' UPSTREAM.sha256 | grep -E '^(doc|src)/' | LC_ALL=C sort)
actual_tree=$(find doc src -type f | LC_ALL=C sort)
if [ "$expected_tree" != "$actual_tree" ]; then
    echo "the native file set differs from the recorded one:" >&2
    diff -u <(echo "$expected_tree") <(echo "$actual_tree") >&2 || true
    echo >&2
    echo "An intentional change to the native source needs an observed failure, a" >&2
    echo "small causal patch, an explicit per-file deviation record in NOTICE.md," >&2
    echo "updated digests here, and a CHANGELOG.md entry in the same change." >&2
    exit 1
fi
echo "the native file set is exactly the recorded 75 files"

# 3a. The release digest must be recorded identically in both records, so the
#     two files cannot disagree about which upstream release this is.
# `-m1` rather than a pipe into `head -1`: with `pipefail` a `head` that closes
# the pipe early sends SIGPIPE to grep and turns a successful match into a
# failed pipeline.
digest_md=$(grep -m1 -oE '[0-9a-f]{64}' UPSTREAM.md)
digest_list=$(grep -m1 -oE '[0-9a-f]{64}' UPSTREAM.sha256)
[ -n "$digest_md" ] || fail "UPSTREAM.md records no sha256 digest"
[ "$digest_md" = "$digest_list" ] ||
    fail "UPSTREAM.md and UPSTREAM.sha256 name different release digests"
echo "the release digest is recorded consistently: $digest_md"

# 3b. The preserved upstream README. README.upstream.md is the exact bytes of
#     the tarball's README; the copy at the root is the imported original.
cmp -s README README.upstream.md ||
    fail "README and README.upstream.md are no longer byte-identical"
echo "README.upstream.md is byte-identical to the imported upstream README"

# 3c. Lua's own grant, in the file that carries it and in the records.
grep -q 'Copyright (C) 1994-2026 Lua.org, PUC-Rio.' src/lua.h ||
    fail "the Lua.org copyright notice is missing from src/lua.h"
for file in NOTICE.md README.md FORK-LICENSE.md; do
    grep -q 'Copyright (C) 1994-2026 Lua.org, PUC-Rio.' "$file" ||
        fail "the upstream copyright notice is missing from $file"
done
grep -q 'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND' FORK-LICENSE.md ||
    fail "FORK-LICENSE.md does not reproduce the MIT permission and warranty text"
echo "the upstream MIT notice is present in src/lua.h and in the records"

# 3d. The tarball ships no test suite -- src/Makefile's `test` target is just
#     `lua -v` -- so no test file may appear in the manifest, and a build must
#     not fetch one to stand in for it.
if awk '/^[0-9a-f]{64}  / { print $2 }' UPSTREAM.sha256 | grep -qE '(^|/)(ltests|test)'; then
    fail "UPSTREAM.sha256 records a test file; the release tarball has no test suite"
fi
echo "the absence of an upstream test suite is recorded"

echo "provenance checks passed"