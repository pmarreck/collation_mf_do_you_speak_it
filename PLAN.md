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

Current test count: 89 passed, 0 failed (21 Zig unit + 68 CLI integration).

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
- [ ] **Lift the 250-significant-digit numeric cap using BLIP's escalating
      length-class idea** (Peter, 2026-07-29 — see `~/Code/BLIP`, his own
      "Byte Length Integer Prefix" project). Today `pushNumericPrimary` puts the
      significant-digit count in ONE byte (`WEIGHT_BASE + N`, N ≤ 250), so two
      numbers agreeing on their first 250 digits compare EQUAL. BLIP-BE solves
      the general problem — magnitude class in the header, big-endian payload
      after, `memcmp`-ordered, and its continuation flag (bit 5) makes the length
      field unbounded, which is exactly the field we capped.
      **Caveat: BLIP cannot drop in verbatim.** Its payload is raw LE/BE bytes
      that freely contain 0x00 and 0x01 (e.g. 256 = `[0xC2,0x01,0x00]`), which
      are our TERM and SEP — that would violate RULES.md #4 (C-safe keys, no
      interior NUL). We don't need BLIP's payload though: ours is already
      digits-as-bytes. Adopt the *length-prefix structure only*, byte-range
      restricted to >= 0x02: keep `0x02+N` for N <= 250 (backward compatible for
      every realistic input), and reserve 0xFD/0xFE/0xFF as escalating
      "longer length follows" classes with the length itself in base-253
      big-endian. Ordering is preserved by construction, since any escalation
      byte exceeds every single-byte length and more digits always means a
      larger number.

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
