#!/usr/bin/env bash
# Integration test: i18n groundwork (PREPARE phase) for --help/--about.
#   --lang <code> + COLLATION_MF_LANG override LANG/LC_*; English is the
#   default/fallback. Localized aliases: --hilfe (German help), --sprache
#   (German alias for --lang). Only en + de exist in prepare phase; unsupported
#   locales WARN (non-fatal) and fall back to English.
#
# The environment is scrubbed of LANG/LC_*/COLLATION_MF_LANG per case so an
# ambient locale on the test host cannot perturb results.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/zig-out/bin/collate"
[[ -x "$CLI" ]] || CLI="$REPO_ROOT/result/bin/collate"
if [[ ! -x "$CLI" ]]; then echo "FAIL: CLI not built; run ./build" >&2; exit 1; fi

# Run collate with a fully-scrubbed locale environment plus any KEY=VAL prefixes.
run() { env -u LANG -u LC_ALL -u LC_MESSAGES -u LANGUAGE -u COLLATION_MF_LANG "$@"; }

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1 -- $2" >&2; }

# want_contains NAME NEEDLE HAYSTACK
want_contains() {
	if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "expected '$2' in: $3"; fi
}
want_missing() {
	if [[ "$3" != *"$2"* ]]; then pass "$1"; else fail "$1" "did NOT expect '$2' in: $3"; fi
}

# ── default: English about/help ──
out=$(run "$CLI" --about 2>/dev/null)
want_contains "default about is English" "opinionated" "$out"
out=$(run "$CLI" --help 2>/dev/null)
want_contains "default help is English" "structural-first" "$out"

# ── --lang de => German about ──
out=$(run "$CLI" --lang de --about 2>/dev/null)
want_contains "--lang de about is German" "Sortierung" "$out"

# ── --lang=de attached form ──
out=$(run "$CLI" --lang=de --about 2>/dev/null)
want_contains "--lang=de attached form" "Sortierung" "$out"

# ── COLLATION_MF_LANG=de => German ──
out=$(run COLLATION_MF_LANG=de "$CLI" --about 2>/dev/null)
want_contains "COLLATION_MF_LANG=de about is German" "Sortierung" "$out"

# ── --lang overrides COLLATION_MF_LANG (en beats de) ──
out=$(run COLLATION_MF_LANG=de "$CLI" --lang en --about 2>/dev/null)
want_contains "--lang en overrides COLLATION_MF_LANG=de" "opinionated" "$out"

# ── COLLATION_MF_LANG overrides LANG (project env beats ambient) ──
out=$(run LANG=en_US.UTF-8 COLLATION_MF_LANG=de "$CLI" --about 2>/dev/null)
want_contains "COLLATION_MF_LANG beats LANG" "Sortierung" "$out"

# ── ambient LANG selects the locale when no app request ──
out=$(run LANG=de_DE.UTF-8 "$CLI" --about 2>/dev/null)
want_contains "ambient LANG=de_DE selects German" "Sortierung" "$out"

# ── LC_ALL takes precedence over LANG (POSIX) ──
out=$(run LANG=en_US.UTF-8 LC_ALL=de_DE.UTF-8 "$CLI" --about 2>/dev/null)
want_contains "LC_ALL beats LANG" "Sortierung" "$out"

# ── localized alias --hilfe => German help (infers de) ──
out=$(run "$CLI" --hilfe 2>/dev/null)
want_contains "--hilfe shows German help" "Optionen" "$out"

# ── --sprache is the German alias for --lang ──
out=$(run "$CLI" --sprache de --about 2>/dev/null)
want_contains "--sprache de selects German" "Sortierung" "$out"

# ── unsupported --lang: WARN on stderr, English on stdout, exit 0 ──
stdout=$(run "$CLI" --lang xx --about 2>/dev/null)
rc=$?
stderr=$(run "$CLI" --lang xx --about 2>&1 >/dev/null)
want_contains "unsupported --lang falls back to English" "opinionated" "$stdout"
want_contains "unsupported --lang warns on stderr" "missing-locale" "$stderr"
if [[ $rc -eq 0 ]]; then pass "unsupported --lang is non-fatal (exit 0)"; else fail "unsupported --lang exit" "rc=$rc"; fi

# ── ambient unsupported LANG must NOT warn (only app requests warn) ──
stderr=$(run LANG=zh_CN.UTF-8 "$CLI" --about 2>&1 >/dev/null)
want_missing "ambient unsupported LANG is silent" "missing-locale" "$stderr"

# ── plain English canonical flags never infer a non-English locale ──
out=$(run "$CLI" --help 2>/dev/null)
want_missing "English --help stays English (no de inference)" "Optionen" "$out"

echo ""
echo "i18n: $PASS passed, $FAIL failed"
exit $FAIL
