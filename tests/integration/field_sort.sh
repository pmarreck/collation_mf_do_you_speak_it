#!/usr/bin/env bash
# Integration test: field / separator sorting in `collate` (à la `sort -t -k`).
#   -t/--field-separator <SEP>  : split each line on SEP (default: whole line)
#   -k/--key <N>                : sort by 1-based field N; ties -> whole line
#   COLLATE_FIELD_SEP           : env default separator, overridden by -t
# The Zig core stays field-agnostic; field extraction happens in the C CLI.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/zig-out/bin/collate"
[[ -x "$CLI" ]] || CLI="$REPO_ROOT/result/bin/collate"
if [[ ! -x "$CLI" ]]; then echo "FAIL: CLI not built; run ./build" >&2; exit 1; fi

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# assert_eq NAME EXPECTED ACTUAL
assert_eq() {
	if [[ "$2" == "$3" ]]; then pass "$1"; else
		fail "$1"$'\n'"    expected: $(printf '%q' "$2")"$'\n'"    actual  : $(printf '%q' "$3")"
	fi
}

# ── sort by 2nd colon field: a:3 b:1 c:2 -> b,c,a ──
out=$(printf 'a:3\nb:1\nc:2\n' | "$CLI" -t: -k2 2>/dev/null)
assert_eq "sort by field 2 (colon)" $'b:1\nc:2\na:3' "$out"

# ── long-form flags ──
out=$(printf 'a:3\nb:1\nc:2\n' | "$CLI" --field-separator : --key 2 2>/dev/null)
assert_eq "long-form --field-separator/--key" $'b:1\nc:2\na:3' "$out"

# ── field 1 is the default when a separator is set but -k omitted ──
out=$(printf 'z:1\na:9\nm:5\n' | "$CLI" -t: 2>/dev/null)
assert_eq "separator set, -k defaults to field 1" $'a:9\nm:5\nz:1' "$out"

# ── natural numeric applies within the chosen field: 2 < 10 < 100 ──
out=$(printf 'x|100\ny|2\nz|10\n' | "$CLI" -t'|' -k2 2>/dev/null)
assert_eq "numeric ordering within field" $'y|2\nz|10\nx|100' "$out"

# ── multi-character separator ──
out=$(printf 'a::3\nb::1\nc::2\n' | "$CLI" -t:: -k2 2>/dev/null)
assert_eq "multi-char separator '::'" $'b::1\nc::2\na::3' "$out"

# ── missing field sorts as empty (empty < everything) ──
# 'lonely' has no separator so field 2 is empty and must come first.
out=$(printf 'k2\tb\nlonely\nk2\ta\n' | "$CLI" -t$'\t' -k2 2>/dev/null)
assert_eq "missing field sorts as empty (first)" $'lonely\nk2\ta\nk2\tb' "$out"

# ── ties on the key field break by the whole line (deterministic) ──
out=$(printf 'b:1\na:1\nc:1\n' | "$CLI" -t: -k2 2>/dev/null)
assert_eq "tie on field breaks by whole line" $'a:1\nb:1\nc:1' "$out"

# ── env COLLATE_FIELD_SEP provides the default separator ──
out=$(printf 'a,3\nb,1\nc,2\n' | COLLATE_FIELD_SEP=, "$CLI" -k2 2>/dev/null)
assert_eq "COLLATE_FIELD_SEP env default" $'b,1\nc,2\na,3' "$out"

# ── -t overrides the env separator ──
out=$(printf 'a:3\nb:1\nc:2\n' | COLLATE_FIELD_SEP=, "$CLI" -t: -k2 2>/dev/null)
assert_eq "-t overrides COLLATE_FIELD_SEP" $'b:1\nc:2\na:3' "$out"

# ── combine with --code-point: field 2 sorted by raw byte order ──
# byte order puts uppercase 'B' (0x42) before lowercase 'a' (0x61).
out=$(printf 'x:a\ny:B\n' | "$CLI" -t: -k2 --code-point 2>/dev/null)
assert_eq "field sort combined with --code-point" $'y:B\nx:a' "$out"

# ── -k without any separator is a usage error (exit 2, clean stdout) ──
stdout=$(printf 'a\nb\n' | "$CLI" -k2 2>/dev/null)
rc=$?
if [[ $rc -eq 2 && -z "$stdout" ]]; then
	pass "-k without separator is a usage error"
else
	fail "-k without separator rc=$rc stdout='$stdout'"
fi

echo ""
echo "field_sort: $PASS passed, $FAIL failed"
exit $FAIL
