#!/usr/bin/env bash
# Integration test: Western-European Latin coverage, end-to-end through the CLI
# (Zig core <- C FFI <- C CLI).
#
# Two halves, deliberately:
#   1) SENSITIVITY — a mechanical classifier over the whole DECLARED coverage
#      set. A character folds to a letter iff it sorts before "zz" (CLASS_LETTER
#      0x40 < CLASS_OTHER 0x50, and a base-'z' letter like ž still loses to the
#      two-element "zz" on the shorter-prefix rule). Every declared character
#      must pass. This is a classifier over a SET, not a spot-check of examples.
#   2) SPECIFICITY — a corpus of deliberately OUT-OF-SCOPE characters that must
#      still fall through to CLASS_OTHER. Without this half, an
#      accept-everything fold table would score 100% on part 1.
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

# folds_to_letter CHAR -> 0 if the char collates as a letter, 1 otherwise.
folds_to_letter() {
	local first
	first=$(printf '%s\nzz\n' "$1" | "$CLI" 2>/dev/null | head -1)
	[[ "$first" != "zz" ]]
}

# assert_covered LANG CHAR... : every char must be letter-class.
assert_covered() {
	local lang="$1"; shift
	local missing=""
	local c
	for c in "$@"; do
		folds_to_letter "$c" || missing+=" $c"
	done
	if [[ -z "$missing" ]]; then
		pass "coverage: $lang ($# chars, all letter-class)"
	else
		fail "coverage: $lang — NOT letter-class:$missing"
	fi
}

# assert_order NAME LINE... : feed reversed, expect the given order out.
assert_order() {
	local name="$1"; shift
	local -a want=("$@")
	local input="" i
	for ((i = ${#want[@]} - 1; i >= 0; i--)); do input+="${want[i]}"$'\n'; done
	local got expected
	got=$(printf '%s' "$input" | "$CLI" 2>/dev/null)
	expected=$(printf '%s\n' "${want[@]}")
	expected=${expected%$'\n'}
	if [[ "$got" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name"$'\n'"    want: $(printf '%q ' "${want[@]}")"$'\n'"    got : $(printf '%q ' $got)"
	fi
}

echo "── sensitivity: declared coverage set must be letter-class ──"
assert_covered French     à â ä ç é è ê ë î ï ô ö ù û ü ÿ æ œ
assert_covered Spanish    á é í ó ú ü ñ
assert_covered Italian    à è é ì î ò ó ù
assert_covered Portuguese á â ã à ç é ê í ó ô õ ú
assert_covered Catalan    à è é í ï ò ó ú ü ç ŀ
assert_covered Romanian   ă â î ș ț ş ţ
assert_covered German     ä ö ü ß
assert_covered Dutch      é ë ï ö ü ĳ
assert_covered uppercase  Æ Œ ẞ Ĳ Ă Ș Ț É Ü Ñ Ç Ŀ

echo "── specificity: out-of-scope must stay CLASS_OTHER ──"
OUT_OF_SCOPE=(中 日 € Ω д ա 🎉 ก ℵ)
oos_bad=""
for c in "${OUT_OF_SCOPE[@]}"; do
	folds_to_letter "$c" && oos_bad+=" $c"
done
if [[ -z "$oos_bad" ]]; then
	pass "specificity: ${#OUT_OF_SCOPE[@]} out-of-scope chars still CLASS_OTHER"
else
	fail "specificity: these wrongly fold to letters:$oos_bad"
fi

echo "── ligature expansions collate as their spelled-out form ──"
assert_order "German ß = ss"      strasse straße stratos
assert_order "French œ = oe"      coeur cœur cor
assert_order "French æ = ae"      aeon æon afar
assert_order "Dutch ĳ = ij"       ijs ĳs iks

echo "── compatibility expansions beyond two letters ──"
assert_order "Roman numeral char = its text" VII VIII Ⅷ
assert_order "Roman numerals among themselves" Ⅰ Ⅳ Ⅷ Ⅻ
assert_order "fraction = digit/slash/digit" 1/2 ½ 3/4
assert_order "fraction denominators numeric" ⅑ ⅒
assert_order "letterlike TM" TM ™ TN
assert_order "letterlike No" No № Np

echo "── Spanish and Romanian primary letters ──"
assert_order "Spanish ñ after n"       nob ñaa ño o
assert_order "Romanian a letters"      az ăa ăz âa âz ba
assert_order "Romanian i letter"       iz îa îz ja
assert_order "Romanian s letter"       sz șa șz ta
assert_order "Romanian t letter"       tz ța țz ua

echo "── Catalan ŀl collates as ll ──"
assert_order "Catalan ŀ base l"   cella ceŀla cellb

echo ""
echo "latin_coverage: $PASS passed, $FAIL failed"
exit "$FAIL"
