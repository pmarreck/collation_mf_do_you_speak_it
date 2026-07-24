#!/usr/bin/env bash
# Integration test: the opinionated HOUSE STYLE ordering, end-to-end through the
# CLI (Zig core <- C FFI <- C CLI). Asserts the concrete orderings from the spec.
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

# assert_order NAME LINE1 LINE2 ... : feed the lines and assert output equals
# them in the given (already-correct) order regardless of input order (we feed
# them reversed to prove the sort actually reordered).
assert_order() {
	local name="$1"; shift
	local -a want=("$@")
	# Build reversed input.
	local input="" line
	local i
	for ((i = ${#want[@]} - 1; i >= 0; i--)); do
		input+="${want[i]}"$'\n'
	done
	local got
	got=$(printf '%s' "$input" | "$CLI" 2>/dev/null)
	local expected
	expected=$(printf '%s\n' "${want[@]}")
	# strip trailing newline from expected for comparison
	expected=${expected%$'\n'}
	if [[ "$got" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name"$'\n'"    want: $(printf '%q ' "${want[@]}")"$'\n'"    got : $(printf '%q ' $got)" >&2
	fi
}

# Rule 1: structural-first + prefix (space before non-space, shorter-prefix-first)
assert_order "structural-first: thing < 'thing ' < thing2 < thingthing" \
	"thing" "thing " "thing2" "thingthing"

# Rule 1: whitespace < digit
assert_order "space before digit: 'test with spaces' < test1" \
	"test with spaces" "test1"

# Rule 1 classes: whitespace < punctuation < digit < letter (single leading char)
assert_order "class order:  space < !punct < 5digit < aletter" \
	" x" "!x" "5x" "ax"

# Rule 2: natural numeric runs
assert_order "natural numeric: file2 < file10 < file100" \
	"file2" "file10" "file100"

# Rule 3 + 5: case-insensitive base, lowercase before uppercase, adjacent
assert_order "case tie-break: apple < Apple (adjacent, lower first)" \
	"apple" "Apple"

# Rule 3: base letter dominates case (apple < BANANA)
assert_order "base dominates case: apple < BANANA" \
	"apple" "BANANA"

# Rule 4: diacritic as secondary (cafe < café < cafz)
assert_order "diacritic secondary: cafe < café < cafz" \
	"cafe" "café" "cafz"

# Rule 6: precomposed accented letter folds to base (é sorts between e and f)
assert_order "precomposed fold: e < é < f" \
	"e" "é" "f"

# A combined real-world-ish list.
assert_order "combined ordering" \
	"apple" "Apple" "cafe" "café" "cafz" "file2" "file10" "zebra"

echo ""
echo "house_style: $PASS passed, $FAIL failed"
exit $FAIL
