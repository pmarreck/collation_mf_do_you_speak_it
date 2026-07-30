#!/usr/bin/env bash
# Integration test: numeric collation end-to-end through the CLI.
#
#   * natural numeric runs (file2 < file10)
#   * ARBITRARY PRECISION — no cap on significant digits
#   * signed numbers, but only when '-' starts the collated string
#   * dotted numbers: versions by default, decimals under -d/--decimal
#
# The big-integer half is checked against `bc`, an INDEPENDENT arbitrary-precision
# oracle (GNU bc, not our code), rather than against hand-written expectations.
# `sort -n` is also arbitrary precision so it corroborates; `sort -g` is NOT
# (long double, ~19 significant digits) and is used here only as a negative
# control to show the failure mode we avoid.
#
# Per Mecha conventions: no `set -e` (it aborts on the intended non-zero exits).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/zig-out/bin/collate"
[[ -x "$CLI" ]] || CLI="$REPO_ROOT/result/bin/collate"

if [[ ! -x "$CLI" ]]; then
	echo "FAIL: CLI not built; run ./build" >&2
	exit 1
fi

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# assert_order NAME [FLAGS...] -- LINE... : feed reversed, expect given order out.
assert_order() {
	local name="$1"; shift
	local -a flags=()
	while [[ $# -gt 0 && "$1" != "--" ]]; do flags+=("$1"); shift; done
	shift # drop the --
	local -a want=("$@")
	local input="" i
	for ((i = ${#want[@]} - 1; i >= 0; i--)); do input+="${want[i]}"$'\n'; done
	local got expected
	got=$(printf '%s' "$input" | "$CLI" "${flags[@]+"${flags[@]}"}" 2>/dev/null)
	expected=$(printf '%s\n' "${want[@]}")
	if [[ "$got" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name"$'\n'"    want: $(printf '%q ' "${want[@]}")"$'\n'"    got : $(printf '%q ' $got)"
	fi
}

echo "── natural numeric runs ──"
assert_order "file2 < file10"        -- file2 file10 file100
assert_order "bare 9 < 10"           -- 9 10 100
assert_order "embedded, multi-run"   -- v1-2 v1-10 v2-1

echo "── arbitrary precision: past the old 250-digit cap ──"
# Two 260-digit numbers differing only at digit 255 — inside the old truncation
# window, so these used to produce identical keys and compare EQUAL.
big_a="1$(printf '0%.0s' $(seq 1 253))4$(printf '9%.0s' $(seq 1 5))"
big_b="1$(printf '0%.0s' $(seq 1 253))7$(printf '9%.0s' $(seq 1 5))"
assert_order "260-digit, differ at digit 255" -- "$big_a" "$big_b"
# One more digit always means a bigger number, across the escalation boundary.
n250="$(printf '9%.0s' $(seq 1 250))"
n251="$(printf '1%.0s' $(seq 1 251))"
assert_order "251 digits > 250 digits" -- "$n250" "$n251"

echo "── differential vs bc (independent arbitrary-precision oracle) ──"
if command -v bc >/dev/null 2>&1; then
	# A generated set of big integers of assorted lengths, deterministic seed.
	corpus="$TMPDIR/collate_bignum_$$.txt"
	awk 'BEGIN{
		srand(20260729);
		for (i = 0; i < 60; i++) {
			len = 200 + int(rand() * 120);   # straddles the 250 boundary
			s = substr("123456789", int(rand()*9)+1, 1);
			for (j = 1; j < len; j++) s = s int(rand()*10);
			print s;
		}
	}' > "$corpus"
	sorted=$("$CLI" "$corpus" 2>/dev/null)
	# Every adjacent pair must satisfy a <= b according to bc.
	bad=0
	prev=""
	while IFS= read -r cur; do
		if [[ -n "$prev" ]]; then
			[[ "$(echo "$prev <= $cur" | bc)" == "1" ]] || bad=$((bad + 1))
		fi
		prev="$cur"
	done <<< "$sorted"
	n=$(wc -l < "$corpus")
	if [[ "$bad" -eq 0 ]]; then
		pass "bc agrees on all $((n - 1)) adjacent pairs of $n big integers"
	else
		fail "bc disagrees on $bad adjacent pair(s)"
	fi
	# Corroborate with `sort -n` (also arbitrary precision) on the whole file.
	if [[ "$sorted" == "$(sort -n "$corpus")" ]]; then
		pass "matches 'sort -n' over the same corpus"
	else
		fail "differs from 'sort -n' over the same corpus"
	fi
	rm -f "$corpus"
else
	echo "  skip: bc not found (oracle unavailable)" >&2
fi

echo "── signed: '-' is a sign ONLY at offset 0 ──"
assert_order "negatives invert magnitude" -- -10 -5 -2 0 2 5 10
assert_order "hyphen stays a separator"   -- peter-3 peter-4 peter-10
assert_order "ISO dates unharmed"         -- 2026-07-29 2026-08-01
assert_order "'-' not before a digit"     -- -abc -abd
assert_order "long negatives invert"      -- "-$n251" "-$n250"

echo "── dots: versions by default, decimals on request ──"
assert_order "default = version order"          -- 1.2 1.9 1.10
assert_order "default, prefixed"                -- v1.9 v1.10
assert_order "--decimal = real number order" -d -- 1.10 1.2 1.9
assert_order "--decimal reads embedded too"  -d -- v1.10 v1.9
assert_order "--decimal negative fractions"  -d -- -2 -1.5 -1.4 -1
assert_order "-d then --version-sort wins"   -d --version-sort -- 1.9 1.10

echo "── grouped numbers: OFF by default ──"
assert_order "default splits on separators"  -- 1,000,000.00 999,999.00
assert_order "default: space splits too"     -- "thing1 000" thing999

echo "── grouped numbers: --decimal absorbs separators between digits ──"
assert_order "comma grouping"             -d -- 1,000.00 10,000.00 10,000.01 100,000.00 999,999.00 1,000,000.00
assert_order "space grouping (SI form)"   -d -- "1 000.00" "10 000.00" "999 999.00" "1 000 000.00"
assert_order "apostrophe (Swiss)"         -d -- "1'000.00" "999'999.00" "1'000'000.00"
assert_order "underscore (programmer)"    -d -- 1_000 999_999 1_000_000
assert_order "embedded run"               -d -- thing999 "thing1 000"
assert_order "varied precision"           -d -- 1.25 1.5 1.75

echo "── grouped numbers: --decimal=, swaps the roles ──"
assert_order "continental convention" --decimal=, -- 1.000,00 10.000,00 10.000,01 100.000,00 999.999,00 1.000.000,00
assert_order "varied precision, comma" --decimal=, -- 1,25 1,5 1,75
assert_order "--decimals= alias works"  --decimals=, -- 1.000,00 999.999,00

echo "── grouped numbers: group-SIZE agnostic (no 3-digit assumption) ──"
# Chosen so the first group's order disagrees with true magnitude.
assert_order "Indian 2-2-3"  -d -- 99,999.00 1,00,000.00 12,34,567.89
assert_order "Chinese 4-group" -d -- 9999,9999 1,0000,0000

echo "── grouped numbers: a separator not between digits is left alone ──"
assert_order "name then number" -d -- "Smith 999" "Smith 1 000"
assert_order "comma-space"      -d -- "abc, 5" "abc, 10"

echo "── the payoff: same VALUES, same order, any convention ──"
en=$(printf '1,000.00\n999,999.00\n1,000,000.00\n10,000.01\n' | "$CLI" -d | sed 's/[,]//g')
de=$(printf '1.000,00\n999.999,00\n1.000.000,00\n10.000,01\n' | "$CLI" --decimal=, | sed 's/[.]//g;s/,/./')
ch=$(printf "1'000.00\n999'999.00\n1'000'000.00\n10'000.01\n" | "$CLI" -d | sed "s/'//g")
if [[ "$en" == "$ch" ]]; then
	pass "English and Swiss forms produce the same value order"
else
	fail "English vs Swiss order differs"$'\n'"    en: $en"$'\n'"    ch: $ch"
fi
# Compare position-by-position rather than textually for the German form.
en_pos=$(printf '1,000.00\n999,999.00\n1,000,000.00\n10,000.01\n' | "$CLI" -d | grep -n . | cut -d: -f1,2 | sed 's/[,.]//g')
de_pos=$(printf '1.000,00\n999.999,00\n1.000.000,00\n10.000,01\n' | "$CLI" --decimal=, | grep -n . | cut -d: -f1,2 | sed 's/[,.]//g')
if [[ "$en_pos" == "$de_pos" ]]; then
	pass "English and German forms produce the same value order"
else
	fail "English vs German order differs"$'\n'"    en: $en_pos"$'\n'"    de: $de_pos"
fi

echo "── grouped numbers: separator validation ──"
if err=$("$CLI" --decimal=X </dev/null 2>&1); then
	fail "--decimal=X should have been rejected"
else
	[[ "$err" == *"must be '.' or ','"* ]] \
		&& pass "--decimal=X rejected with a clear message" \
		|| fail "--decimal=X rejected but message was: $err"
fi

echo "── negative control: what sort -g gets wrong ──"
# 25 nines vs 1e25 both collapse to the same long double, so -g ties and falls
# back to byte order, which is inverted here. We must NOT do that.
g_small="9999999999999999999999999"
g_big="10000000000000000000000000"
assert_order "we beat sort -g on precision" -- "$g_small" "$g_big"
if command -v bc >/dev/null 2>&1; then
	[[ "$(echo "$g_small < $g_big" | bc)" == "1" ]] \
		&& pass "bc confirms the expected direction" \
		|| fail "bc contradicts the test's premise"
fi

echo ""
echo "numeric_sort: $PASS passed, $FAIL failed"
exit "$FAIL"
