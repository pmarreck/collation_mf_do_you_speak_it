---
purpose: Work plan and roadmap for collation_mf_do_you_speak_it
audience: agent
maintained_by: agent
---

# PLAN — collation_mf_do_you_speak_it

## Done (v0.1.0 + follow-ups)

- [x] Phases 0-3 — scaffold, code-point fallback, opinionated house style, and
      the `collate` CLI. All green via `nix build` + `./test`. (2026-07-23 EST)
- [x] Static-musl native target so the binary runs on NixOS. (2026-07-23)
- [x] Benchmark suite `./bm` — hyperfine comparison vs coreutils `sort`
      (`LC_ALL=C` + `en_US.UTF-8`), ICU (`ucol_getSortKey`), and glibc `strcoll`;
      logs `bench/<machine-id>.ndjson` (`_meta` header); + machine-independent
      `O(n log n)` scaling gate (N,2N,4N,8N, fails on >=3x). Honest numbers in
      README: collate house is ~1.5x faster than glibc locale collation and
      reproducible, but slower than `LC_ALL=C sort` (byte order). (2026-07-24)
- [x] Field/separator sorting in the CLI: `-t/--field-separator`, `-k/--key`,
      `COLLATE_FIELD_SEP` env; extraction in the C CLI (Zig core stays
      field-agnostic). 11 integration tests. (2026-07-24)
- [x] i18n groundwork (PREPARE phase): typed message table (en + de demo),
      `--lang`/`COLLATION_MF_LANG`/`LC_*` precedence, English fallback,
      localized aliases `--hilfe`/`--sprache`. 16 integration tests. Decision
      recorded in RULES.md. (2026-07-24)
- [x] Mechatron Prime CI: `.mechatron-prime/targets` (packages.default +
      checks.build/test, all verified to build); README badge swapped from the
      retired Garnix to the dynamic Mechatron badge. (2026-07-24)

- [x] Housekeeping: trashed 4 stale `result-N` nix GC roots (leftovers from a
      one-off multi-installable `nix build` during CI target verification on
      07-24 — no committed script creates them; `./build` and `./bm` each build
      a single installable and only ever write `result`). Added `dirtree note`
      annotations for every notable path (there were zero). Reindexed codescan.
      (2026-07-29 13:15 EDT)

- [x] **Ligature expansions + broadened Latin coverage.** New `foldExpansion`
      table (ß→ss, ẞ→SS, œ/Œ→oe, æ/Æ→ae, ĳ/Ĳ→ij) — a 1:1 character→letter map
      could not express these, so they had all been falling through to
      CLASS_OTHER and sorting after EVERY letter. Expansions emit two L1 letters
      and two L2/L3 bytes to keep levels aligned, and carry a distinct tertiary
      rank (CASE_*_LIG) so `ß` and `ss` share primary+secondary (sort adjacent)
      without collapsing to a tie. Added Romanian ă/ș/ț + legacy cedilla ş/ţ,
      and Catalan ŀ (folds to bare `l`, so `ŀl` collates as `ll`). Coverage now
      100% for French, Spanish, Italian, Portuguese, Catalan, Romanian, German,
      Dutch (was 16/18, 7/7, 8/8, 12/12, 10/11, **2/7**, **3/4**, 5/6).
      6 new Zig unit tests + `tests/integration/latin_coverage.sh` (20 assertions,
      sensitivity over the declared set + specificity corpus). Both new
      assertions mutation-verified: knocking out the ș row and desyncing the
      expansion level-count each produce a failure. (2026-07-29 23:24 EDT)

- [x] **Signed numbers + optional decimal mode.** A `-` is a minus sign only when
      it starts the collated string (Peter's rule — otherwise `peter-3`/`peter-4`
      and ISO dates sort absurdly); under `-t`/`-k` that means the start of the
      FIELD, which needed no extra plumbing. Negatives get class 0x28 (between
      punctuation and digits) with complemented length+digit weights so magnitude
      inverts under plain memcmp, plus a NEG_END sentinel so "no fraction" sorts
      last (-1.5 < -1). Dots stay SEPARATORS by default (version semantics,
      1.9 < 1.10 — Peter reversed an earlier decision here, correctly: dotted data
      in the wild is overwhelmingly version-shaped); real-number reading is opt-in
      via `OPT_DECIMAL` / `-d`/`--decimal`, with `--version-sort` as the explicit
      default so a later arg can override. 11 new unit tests + 20 CLI tests.
      Documented end to end in `docs/NUMERIC.md`. (2026-07-29 23:56 EDT)
- [x] `docs/` is no longer an empty placeholder — `docs/NUMERIC.md` covers the
      technique, the BLIP derivation, advantages, and all 10 caveats.
      (2026-07-29 23:56 EDT)

- [x] **Grouped numbers under `--decimal[=SEP]`.** Peter's insight: if you are
      sorting numbers, the separator convention does not matter as long as the
      numbers are merged rather than split — because absorbing separators is
      multiplication by a constant 10^k, which preserves order. (His "consistent
      within the list" condition is really about PRECISION, and even that is
      handled, since the fraction compares left-aligned — left-alignment IS the
      padding.) `-d` / `--decimal=,` declares the decimal mark; every other
      candidate (space, NBSP, thin space, apostrophe, underscore, and the other
      of ','/'.') is absorbed whenever it sits BETWEEN two digits. Absorption is
      group-SIZE agnostic per Peter's point 1, so Indian 2-2-3 and Chinese
      4-grouping both work; "between two digits" also keeps "Smith 1 000" and
      "abc, 5" intact. Payoff: English/German/Swiss/SI spellings of the same
      values all sort identically, so the localization ambiguity stops mattering.
      SCOPE CHANGE: decimals now apply to EVERY number, not just a leading one
      (required by "thing1 000" > "thing999"); the sign rule is unchanged at
      offset 0. Consequence, documented: do not pass `--decimal` version strings.
      7 new unit tests + 19 CLI tests. (2026-07-30 10:45 EDT)

- [x] **Scientific notation (`-s`/`--sci`/`--scientific`) + `--numeric`.**
      Numbers normalize to (exponent, mantissa) form; crucially this includes
      numbers with NO explicit exponent (they are exponent 0), so a mixed list
      like `1234` / `2e5` orders correctly instead of being UB as originally
      scoped. `-n`/`--num`/`--numeric` = scientific + decimal; `--dec` alias
      added; all three take the same `=SEP` grammar. For negatives the whole
      magnitude inverts INCLUDING the exponent, via a composed flip term
      (`exp_neg != value_neg`). Mutation-tested: weakening the flip term,
      subtracting instead of adding the normalization exponent, and dropping the
      mantissa inversion are all caught. One equivalent mutant found and REMOVED
      rather than papered over — the zero flag's inversion for negatives was dead
      logic, since NEG_END already outranks any exponent-sign byte; negative-zero
      ordering is now pinned by explicit tests. 9 new unit tests + 18 CLI tests,
      incl. a bc differential over 50 generated scientific values (exponents
      -20..+20). (2026-07-30 14:00 EDT)

Current test count: 175 passed, 0 failed (51 Zig unit + 124 CLI integration).

## Open follow-ups

- [ ] Mechatron webhook provisioning from Thelio (`provision-mechatron-webhooks`)
      — needs the host secret; see report if it required interactive sudo.
- [ ] Document the CJK scope boundary in README "Limits": CJK currently falls
      into CLASS_OTHER (code-point order) — reproducible and non-corrupting, but
      NOT linguistically ordered. State the escape hatch explicitly: supply a
      reading/romanization column and sort it with `-t`/`-k` (this is what
      Japanese systems actually do — the yomi field), which needs no dictionary
      in our binary.
- [ ] Fullwidth/halfwidth folding (U+FF00–U+FFEF, ~225 entries, NO dictionary):
      fold fullwidth ASCII to ASCII and halfwidth katakana to fullwidth. Today a
      fullwidth `５` is CLASS_OTHER, so fullwidth numerals get NO natural-numeric
      treatment and fullwidth Latin sorts after every letter. Cheap real win.
- [ ] `docs/` is an empty placeholder — populate (a `docs/CJK.md` scope note is
      the obvious first tenant) or remove it.
- [ ] `strcoll8` allocates two temp keys per call; add an allocation-free
      streaming level-by-level comparator for the common early-exit case.
- [ ] Numeric follow-ups now that signs and decimals exist (all documented as
      caveats in `docs/NUMERIC.md`, none currently a silent surprise):
      explicit `+` as a sign (today `+5 < -3`, which is wrong when `+` and `-`
      are mixed); and deciding whether
      leading-zero collisions (`007` == `7`) should become a tertiary-level
      distinction so the library's order is total without relying on the CLI's
      raw-byte tie-break.

## Deferred (future, noted in README Limits)

- [ ] i18n ENFORCE phase: all 50 locales, compile/test enforcement, bilingual
      errors, RTL handling, alias-collision comptime guard. Flip when the CLI
      surface stabilizes (see the i18n skill checklist).
- [ ] Full Unicode normalization: fold DECOMPOSED combining-mark sequences to
      equal precomposed forms (v1 folds only precomposed Latin).
- [ ] Broaden diacritic coverage beyond Latin-1 + common Latin Extended-A.
- [ ] Wire the reserved option bits (`COLLATION_MF_NUMERIC`,
      `COLLATION_MF_CASE_SENSITIVE`) to actually toggle behavior.
- [ ] Optional locale tailoring: a real `collation_mf_open_locale`. (This is the
      architectural hook CJK would need — ICU calls it "tailoring"; it is a
      per-locale reordering layer, not more rows in `foldLetter`.)
- [ ] Optional table-only CJK tier behind a build flag (keeps the default binary
      small): hangul is algorithmic (jamo decomposition — zero data, and its
      code-point order is ALREADY correct dictionary order); kana is a ~200-entry
      gojūon table plus the JIS X 4061 tie-break levels (voicing/small-kana/
      hiragana-vs-katakana); Han by Unihan `kTotalStrokes`/`kRSUnicode`. Stops
      short of pinyin/yomi — those need real dictionaries (polyphone and reading
      disambiguation is word-level, not character-level) and would blow the
      "small, no-ICU" thesis.
- [ ] SIMD sort-key generation for throughput.
- [ ] `./fuzz`: property-fuzz `sortKeyAlloc` — the sort-key-order ==
      compare-order invariant must never break on random bytes.
