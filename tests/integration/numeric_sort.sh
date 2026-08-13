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
assert_order "-n then --version-sort wins"   -n --version-sort -- 1.9 1.10
assert_order "--numeric then --version-sort wins" --numeric --version-sort -- 1.9 1.10
assert_order "-s then --version-sort wins"   -s --version-sort -- 1.9 1.10
assert_order "--scientific then --version-sort wins" --scientific --version-sort -- 1.9 1.10
assert_order "--version-sort resets comma mode too" --numeric=, --version-sort --scientific -- 1,5e4 2e3

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

echo "── scientific notation ──"
assert_order "OFF by default ('e' is a letter)"  -- 1e10 2e5
assert_order "-s orders by value"             -s -- 2e5 1e10
assert_order "--sci alias"                  --sci -- 9e2 1e3
assert_order "--scientific alias"    --scientific -- 1.5e3 1.6e3
assert_order "negative exponents invert"      -s -- 1e-10 1e-5 1e5
assert_order "capital E and explicit +"       -s -- 1E10 2E10
assert_order "plain numbers normalized"       -s -- 999 1e3 1001
assert_order "mixed notation list"            -s -- 1234 2e5 1e10
assert_order "zero placement"                 -s -- -5 -1e-999 0 1e-999 5
assert_order "negatives invert wholly"        -s -- -1e10 -2e5 -1e3 -9e2
assert_order "bare 'e' is not an exponent"    -s -- 3employees 4employees

echo "── --numeric = scientific + grouping ──"
assert_order "-n does both"                   -n -- 1,234 2e5 999,999 1,000,000
assert_order "--num alias"                 --num -- 999,999 1,000,000
assert_order "--numeric alias"         --numeric -- 2e5 1,000,000
assert_order "--numeric=, continental" --numeric=, -- 1.000,00 1,5e3 999.999,00
assert_order "--sci does NOT absorb"        --sci -- 1,000,000 999,999
assert_order "--dec alias"                  --dec -- 999,999.00 1,000,000.00

echo "── differential: scientific vs bc over a generated corpus ──"
if command -v bc >/dev/null 2>&1; then
	sci_corpus="$TMPDIR/collate_sci_$$.txt"
	awk 'BEGIN{
		srand(20260730);
		for (i = 0; i < 50; i++) {
			m = int(rand()*9)+1; f = int(rand()*1000);
			e = int(rand()*40) - 20;
			printf "%d.%03de%d\n", m, f, e;
		}
	}' > "$sci_corpus"
	sci_sorted=$("$CLI" -s "$sci_corpus" 2>/dev/null)
	bad=0; prev=""
	while IFS= read -r cur; do
		if [[ -n "$prev" ]]; then
			# bc has no exponent syntax, so expand aeb -> a*10^b by hand.
			pm=${prev%e*}; pe=${prev#*e}
			cm=${cur%e*};  ce=${cur#*e}
			ok=$(echo "scale=60; ($pm * 10^($pe)) <= ($cm * 10^($ce))" | bc)
			[[ "$ok" == "1" ]] || bad=$((bad + 1))
		fi
		prev="$cur"
	done <<< "$sci_sorted"
	if [[ "$bad" -eq 0 ]]; then
		pass "bc agrees on all adjacent pairs of 50 scientific values"
	else
		fail "bc disagrees on $bad adjacent scientific pair(s)"
	fi
	rm -f "$sci_corpus"
else
	echo "  skip: bc not found" >&2
fi

echo "── explicit '+' sign ──"
assert_order "default: '+' is punctuation"    -- +5 5
assert_order "-d: '+' outranks negatives"  -d -- -3 +5
assert_order "-s: '+' outranks negatives"  -s -- -10 +2
assert_order "-n: signed positives order"  -n -- +5 +10
assert_order "'+' not at offset 0"         -d -- peter+3 peter+4

echo "── leading zeros: a real distinction by default, a tie in numeric modes ──"
assert_order "default distinguishes"          -- 007 07 7
assert_order "default, embedded"              -- word007 word7
assert_order "default, negatives"             -- -007 -7
assert_order "value still dominates"          -- 007 8
# In numeric modes they are the same number, so the CLI's raw-byte tie-break
# decides and the pair must come out in byte order either way it is fed.
for flag in -d -s; do
	a=$(printf '007\n7\n' | "$CLI" $flag | tr '\n' ' ')
	b=$(printf '7\n007\n' | "$CLI" $flag | tr '\n' ' ')
	if [[ "$a" == "$b" ]]; then
		pass "$flag: 007 and 7 tie (order independent of input order)"
	else
		fail "$flag: 007/7 not a tie — got '$a' vs '$b'"
	fi
done

echo "── folded digit forms take part in natural-numeric ordering ──"
assert_order "fullwidth, embedded"       -- word2 word５ word10
assert_order "fullwidth, bare"           -- ９ １０
assert_order "run may MIX widths"        -- 9 １0 11
assert_order "math bold digits"          -- 2 𝟗 𝟏𝟎
assert_order "math double-struck"        -- 𝟚 10
assert_order "math monospace"            -- 𝟸 10
assert_order "folded under -d"        -d -- ９ １０
assert_order "folded under -s"        -s -- ９ １０
assert_order "folded signed integer"     -- -10 -５ -2
assert_order "folded scientific fractions" -s -- 0.０ 0.0001 0.0０1 0.009
# Same value, so this must be a real ordering rather than an input-order artifact.
one_a=$(printf '1\n１\n' | "$CLI" | tr '\n' ' ')
one_b=$(printf '１\n1\n' | "$CLI" | tr '\n' ' ')
if [[ "$one_a" == "$one_b" && "$one_a" == "1 １ " ]]; then
	pass "ASCII and fullwidth 1 stay distinguishable, order independent of input"
else
	fail "1 vs １ unstable or misordered: '$one_a' vs '$one_b'"
fi
# Specificity: fullwidth and mathematical LETTERS must not become digits.
letters_bad=""
for c in Ａ ａ 𝐀 𝔄 𝕬; do
	first=$(printf '%s\nzz\n' "$c" | "$CLI" | head -1)
	[[ "$first" == "zz" ]] || letters_bad+=" $c"
done
if [[ -z "$letters_bad" ]]; then
	pass "fullwidth/math letters still CLASS_OTHER (not folded to digits)"
else
	fail "these wrongly fold:$letters_bad"
fi

echo "── --roman: whole-token Roman numerals by value ──"
assert_order "by value"              --roman -- IV VII IX X XL L MCMXCIV MMXXVI
assert_order "embedded in text"      --roman -- "Chapter IV" "Chapter VII" "Chapter IX"
assert_order "lowercase forms"       --roman -- iv vii ix
assert_order "Unicode numeral chars" --roman -- Ⅳ Ⅶ Ⅸ
assert_order "OFF by default"                -- IX VII
# Words built only from Roman letters must stay words. Before the whole-token
# fix these inverted, because a failed parse re-entered mid-word and matched the
# trailing L as 50 and C as 100.
assert_order "CIVIC/CIVIL stay words" --roman -- CIVIC CIVIL
assert_order "DID/DIM stay words"     --roman -- DID DIM
assert_order "MIL/MILL stay words"    --roman -- MIL MILL
assert_order "LID/LIDS stay words"    --roman -- LID LIDS
assert_order "mixed case stays a word" --roman -- Mix Mob
assert_order "non-canonical IIII"     --roman -- IIII IIIJ

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
