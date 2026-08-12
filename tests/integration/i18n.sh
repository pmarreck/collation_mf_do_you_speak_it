#!/usr/bin/env bash
# Integration test: i18n groundwork (PREPARE phase) for --help/--about.
#   --lang <code> + ROMANTIC_COLLATION_LANG override LANG/LC_*; English is the
#   default/fallback. Supported catalogs: en, de, fr, es, it, pt_br, ca, ro.
#   Each non-English catalog has a localized help and language alias that infer
#   its UI language. Unsupported locales WARN (non-fatal) and fall back to
#   English.
#
# The environment is scrubbed of LANG/LC_*/ROMANTIC_COLLATION_LANG per case so an
# ambient locale on the test host cannot perturb results.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLI="$REPO_ROOT/zig-out/bin/collate"
[[ -x "$CLI" ]] || CLI="$REPO_ROOT/result/bin/collate"
if [[ ! -x "$CLI" ]]; then echo "FAIL: CLI not built; run ./build" >&2; exit 1; fi

# Run collate with a fully-scrubbed locale environment plus any KEY=VAL prefixes.
run() { env -u LANG -u LC_ALL -u LC_MESSAGES -u LANGUAGE -u ROMANTIC_COLLATION_LANG "$@"; }

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
want_contains "English help names Spanish/Romanian slots" "n < ñ < o" "$out"

# ── --lang de => German about ──
out=$(run "$CLI" --lang de --about 2>/dev/null)
want_contains "--lang de about is German" "Sortierung" "$out"

# ── --lang=de attached form ──
out=$(run "$CLI" --lang=de --about 2>/dev/null)
want_contains "--lang=de attached form" "Sortierung" "$out"

# ── ROMANTIC_COLLATION_LANG=de => German ──
out=$(run ROMANTIC_COLLATION_LANG=de "$CLI" --about 2>/dev/null)
want_contains "ROMANTIC_COLLATION_LANG=de about is German" "Sortierung" "$out"

# ── --lang overrides ROMANTIC_COLLATION_LANG (en beats de) ──
out=$(run ROMANTIC_COLLATION_LANG=de "$CLI" --lang en --about 2>/dev/null)
want_contains "--lang en overrides ROMANTIC_COLLATION_LANG=de" "opinionated" "$out"

# ── ROMANTIC_COLLATION_LANG overrides LANG (project env beats ambient) ──
out=$(run LANG=en_US.UTF-8 ROMANTIC_COLLATION_LANG=de "$CLI" --about 2>/dev/null)
want_contains "ROMANTIC_COLLATION_LANG beats LANG" "Sortierung" "$out"

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

# ── localized aliases must be disjoint from English canonical options ──
# Classify every current localized alias against the complete English option set;
# a copied English alias would silently switch the UI language.
english_options=(--help --about --version --lang --field-separator --key --code-point --decimal --decimals --dec --scientific --sci --roman --numeric --num --version-sort)
localized_aliases=(--hilfe --sprache --aide --langue --ayuda --idioma --aiuto --lingua --ajuda --linguagem --ajut --llengua --ajutor --limba)
alias_collision=0
for localized in "${localized_aliases[@]}"; do
	for english in "${english_options[@]}"; do
		if [[ "$localized" == "$english" ]]; then
			fail "localized alias $localized is disjoint from English options" "collides with $english"
			alias_collision=1
		fi
	done
done
if [[ $alias_collision -eq 0 ]]; then
	pass "14 localized aliases are disjoint from 16 English options (224 comparisons)"
fi

# An explicit language code overrides the UI language inferred from a localized
# help alias, regardless of option order.
out=$(run "$CLI" --aide --lang es --about 2>/dev/null)
want_contains "explicit --lang overrides localized help inference" "configuración regional" "$out"

# ── Romance-language catalog availability + localized aliases ──
# code, expected localized marker, localized --help alias, localized --lang alias
check_romance_locale() {
	local code="$1" marker="$2" help_alias="$3" lang_alias="$4"
	local locale_help about alias_help alias_lang
	locale_help=$(run "$CLI" --lang "$code" --help 2>/dev/null)
	want_contains "--lang $code selects its help" "$marker" "$locale_help"
	want_contains "--lang $code help names primary Latin slots" "n < ñ < o" "$locale_help"
	about=$(run "$CLI" --lang "$code" --about 2>/dev/null)
	want_contains "--lang $code selects its about" "$marker" "$about"
	alias_help=$(run "$CLI" "$help_alias" 2>/dev/null)
	want_contains "$help_alias infers $code" "$marker" "$alias_help"
	alias_lang=$(run "$CLI" "$lang_alias" "$code" --about 2>/dev/null)
	want_contains "$lang_alias selects $code" "$marker" "$alias_lang"
}

check_romance_locale fr "paramètres régionaux" --aide --langue
check_romance_locale es "configuración regional" --ayuda --idioma
check_romance_locale it "criterio proprio" --aiuto --lingua
check_romance_locale pt_br "configuração regional" --ajuda --linguagem
out=$(run "$CLI" --lang pt_BR.UTF-8 --about 2>/dev/null)
want_contains "pt_BR.UTF-8 selects Brazilian Portuguese" "configuração regional" "$out"
stdout=$(run "$CLI" --lang pt_PT --about 2>/dev/null)
stderr=$(run "$CLI" --lang pt_PT --about 2>&1 >/dev/null)
want_contains "pt_PT does not select Brazilian Portuguese" "opinionated" "$stdout"
want_contains "pt_PT warns as an unavailable catalog" "missing-locale" "$stderr"
check_romance_locale ca "configuració regional" --ajut --llengua
check_romance_locale ro "configurare regională" --ajutor --limba

echo ""
echo "i18n: $PASS passed, $FAIL failed"
exit $FAIL
