#!/usr/bin/env bash
# Integration test (MFIC differential oracle): `collate --code-point` must
# reproduce `LC_ALL=C sort` EXACTLY, over a generated corpus — not one example,
# but a whole set spanning whitespace, punctuation, digits, mixed case, and
# multi-byte UTF-8. `LC_ALL=C sort` is an INDEPENDENT oracle (coreutils, not our
# code), so agreement is meaningful.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/zig-out/bin/collate"
[[ -x "$CLI" ]] || CLI="$REPO_ROOT/result/bin/collate"

if [[ ! -x "$CLI" ]]; then
	echo "FAIL: CLI not built; run ./build" >&2
	exit 1
fi
if ! command -v sort >/dev/null 2>&1; then
	echo "FAIL: coreutils 'sort' not found (needed as the differential oracle)" >&2
	exit 1
fi

WORK="${TMPDIR:-/tmp}/collate_diff_test.$$"
mkdir -p "$WORK"
trap 'command rm -rf "$WORK" 2>/dev/null' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

CORPUS="$WORK/corpus.txt"

# Deterministic corpus: build a set that exercises every discriminating class.
{
	# whitespace / prefix cases
	printf '%s\n' "thing" "thing " "thing2" "thingthing" "test with spaces" "test1"
	# leading class representatives
	printf '%s\n' " x" "!x" "\"x" "#x" "5x" "9x" "Ax" "ax" "~x"
	# case mixes
	printf '%s\n' "apple" "Apple" "APPLE" "aPPLe" "banana" "Banana" "BANANA" "Zebra" "zebra"
	# numeric runs
	for n in 1 2 9 10 11 100 101 999 1000; do printf 'file%s\n' "$n"; done
	# multi-byte UTF-8 (accented + non-latin) — code-point order is byte order
	printf '%s\n' "café" "cafe" "cafz" "résumé" "resume" "naïve" "naive" "Öl" "ol" "ñandú" "zzz"
	printf '%s\n' "日本語" "Ελληνικά" "Москва" "€uro" "©opyright"
	# programmatic combinations to make it a real set, not a handful
	for p in a A z Z m 0 9 _ - .; do
		for s in 1 2 10 a A "" " "; do
			printf '%s%s\n' "$p" "$s"
		done
	done
	# duplicates (must not reorder differently between the two)
	printf '%s\n' "dup" "dup" "dup"
} > "$CORPUS"

ours=$("$CLI" --code-point "$CORPUS" 2>/dev/null)
theirs=$(LC_ALL=C sort "$CORPUS" 2>/dev/null)

if [[ "$ours" == "$theirs" ]]; then
	pass "collate --code-point == LC_ALL=C sort over $(wc -l < "$CORPUS" | tr -d ' ')-line corpus"
else
	fail "code-point sort diverges from LC_ALL=C sort"
	diff <(printf '%s\n' "$theirs") <(printf '%s\n' "$ours") | head -20 >&2
fi

# Also verify the short-flag alias -c behaves identically.
ours_c=$("$CLI" -c "$CORPUS" 2>/dev/null)
if [[ "$ours_c" == "$theirs" ]]; then
	pass "-c alias matches --code-point"
else
	fail "-c alias diverges"
fi

# And that piping via stdin gives the same result as the file path.
ours_stdin=$("$CLI" --code-point < "$CORPUS" 2>/dev/null)
if [[ "$ours_stdin" == "$theirs" ]]; then
	pass "--code-point via stdin matches file input"
else
	fail "--code-point stdin diverges from file input"
fi

echo ""
echo "code_point_differential: $PASS passed, $FAIL failed"
exit $FAIL
