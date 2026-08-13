#!/usr/bin/env bash
# Integration test: `collate` CLI surface (help/about/version, stdin forms,
# file input incl. spaces in path, error paths, empty input).
#
# Per Mecha conventions: no `set -e` (masks intended non-zero exits). `set -u`
# catches undefined vars without that hazard.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/zig-out/bin/collate"
[[ -x "$CLI" ]] || CLI="$REPO_ROOT/result/bin/collate"

if [[ ! -x "$CLI" ]]; then
	echo "FAIL: CLI not built (looked in zig-out/bin and result/bin); run ./build" >&2
	exit 1
fi

WORK="${TMPDIR:-/tmp}/collate_cli_test.$$"
mkdir -p "$WORK"
trap 'command rm -rf "$WORK" 2>/dev/null' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# ── --version ──
out=$("$CLI" --version 2>/dev/null)
[[ "$out" == "0.1.0" ]] && pass "--version prints 0.1.0" || fail "--version got '$out'"

# ── --about (one line, contains name + platform) ──
out=$("$CLI" --about 2>/dev/null)
if [[ "$out" == collate\ 0.1.0\ * && $(printf '%s' "$out" | wc -l) -eq 0 ]]; then
	pass "--about is one line with version"
else
	fail "--about got '$out'"
fi

# ── -h / --help ──
if "$CLI" --help 2>/dev/null | grep -q "structural-first"; then
	pass "--help documents the house style"
else
	fail "--help missing house-style docs"
fi

# ── unknown option => exit 2, message on stderr (not stdout) ──
stdout=$(printf 'a\n' | "$CLI" --bogus 2>/dev/null)
rc=$?
if [[ $rc -eq 2 && -z "$stdout" ]]; then
	pass "unknown option exits 2 with clean stdout"
else
	fail "unknown option rc=$rc stdout='$stdout'"
fi

# ── empty input => empty output, exit 0 ──
out=$(printf '' | "$CLI" 2>/dev/null)
rc=$?
if [[ $rc -eq 0 && -z "$out" ]]; then
	pass "empty input => empty output, rc 0"
else
	fail "empty input rc=$rc out='$out'"
fi

# ── stdin default vs '-' vs '@stdin' agree ──
data=$'banana\napple\nApple\n'
a=$(printf '%s' "$data" | "$CLI" 2>/dev/null)
b=$(printf '%s' "$data" | "$CLI" - 2>/dev/null)
c=$(printf '%s' "$data" | "$CLI" @stdin 2>/dev/null)
if [[ "$a" == "$b" && "$b" == "$c" ]]; then
	pass "stdin default / - / @stdin agree"
else
	fail "stdin forms disagree: '$a' vs '$b' vs '$c'"
fi

# ── file input, including a path WITH SPACES ──
spacey="$WORK/dir with spaces/in put.txt"
mkdir -p "$WORK/dir with spaces"
printf 'file10\nfile2\n' > "$spacey"
out=$("$CLI" "$spacey" 2>/dev/null)
if [[ "$out" == $'file2\nfile10' ]]; then
	pass "file input with spaces in path"
else
	fail "file-with-spaces got '$out'"
fi

# ── missing file => exit 1, error on stderr only ──
stdout=$("$CLI" "$WORK/nope.txt" 2>/dev/null)
rc=$?
if [[ $rc -eq 1 && -z "$stdout" ]]; then
	pass "missing file exits 1 with clean stdout"
else
	fail "missing file rc=$rc stdout='$stdout'"
fi

# ── final line without trailing newline is still sorted ──
out=$(printf 'b\na' | "$CLI" 2>/dev/null)
if [[ "$out" == $'a\nb' ]]; then
	pass "final line w/o newline is handled"
else
	fail "no-trailing-newline got '$out'"
fi

# ── failed stdout write => exit 1 with captured diagnostic ──
if [[ -e /dev/full ]]; then
	printf 'a\n' | "$CLI" >/dev/full 2>"$WORK/write-error.txt"
	rc=$?
	err=$(<"$WORK/write-error.txt")
	if [[ $rc -eq 1 && "$err" == *"write error"* ]]; then
		pass "stdout write failure exits 1"
	else
		fail "stdout write failure rc=$rc stderr='$err'"
	fi
else
	echo "  skip: /dev/full unavailable (C unit still covers write failure)" >&2
fi

echo ""
echo "cli_surface: $PASS passed, $FAIL failed"
exit $FAIL
