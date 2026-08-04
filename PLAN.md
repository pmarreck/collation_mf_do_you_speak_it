---
purpose: Work plan and roadmap for romantic_collation
audience: agent
maintained_by: agent
---

# PLAN — romantic_collation

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
      `--lang`/`ROMANTIC_COLLATION_LANG`/`LC_*` precedence, English fallback,
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

- [x] **Explicit `+` sign, and leading zeros as a default distinction** (Peter,
      2026-07-31). `+` is a sign only under `-d`/`-s`/`-n` and only at offset 0;
      in the default text sort it stays punctuation. This fixes `+5` sorting
      BELOW every negative in numeric modes (punctuation ranks under CLASS_NEG).
      Leading zeros now carry a TERTIARY weight in the default sort, so
      `007 < 07 < 7` and `-007 < -7` are real orderings — the default order is
      total instead of leaning on the CLI's raw-byte tie-break. In the numeric
      modes they deliberately still tie, since there they are the same number.
      6 new unit tests + 10 CLI tests. (2026-07-31 20:30 EDT)
- [x] CJK scope boundary documented in README: code-point order today, why it
      needs dictionaries rather than tables (pinyin/polyphones, yomi, hangul as
      the exception), and the reading-column + `-t`/`-k` escape hatch.
      (2026-07-31 20:30 EDT)

- [x] **Folded digit forms take part in natural-numeric ordering** (Peter's
      items 1 and 4, 2026-07-31). `digitAt()` folds ASCII, fullwidth
      (U+FF10..FF19), and all five Mathematical Alphanumeric digit styles
      (U+1D7CE..1D7FF, arithmetic rather than a table) BEFORE the digit-run scan,
      so they sort as numbers instead of landing in CLASS_OTHER after every
      letter. A single run may mix widths (`１0` == 10). Folded forms carry a
      SECONDARY style weight so `1` < `１` rather than tying, keeping the order
      total. The ASCII test stays a single byte compare ahead of any decoding, so
      the common path is unchanged.
      Required converting every byte-wise digit loop to be code-point aware:
      `pushNumericPrimary`, `countSigDigits`, `emitSigDigits`, `emitFracDigits`,
      `leadingZeroWeight`, `scanGroupedNumber`, `parseLeadingNumber`, and the
      main scanner branch. Bug found during this: `pushNumericPrimary` gated on
      the code-point count but still EMITTED `sig.len` (bytes), so a fullwidth
      digit counted as 3 and `５` sorted after `10`. 6 new unit tests + 11 CLI
      tests. (2026-07-31 22:25 EDT)

- [x] **(b) General compatibility EXPANSION.** `foldExpansion` returned exactly
      two base letters, which could not express `Ⅷ` → `VIII` (four) or `½` →
      `1/2` (digits plus punctuation, not letters at all). Replaced by
      `compatExpand`, which returns replacement TEXT that `emitExpansion`
      re-scans with the ordinary rules — so a digit run inside a replacement
      still sorts numerically, which is why ⅑ (1/9) correctly precedes ⅒ (1/10).
      Covers the Latin ligatures as before, Roman numeral characters
      U+2160..2180, vulgar fractions, and ™ / № / ℅. ↁ ↂ ↇ ↈ are deliberately
      left in CLASS_OTHER rather than given a wrong ASCII spelling.
      Design point found the hard way: the expansion marker must live at
      TERTIARY. Marking expanded digits at secondary broke the defining property
      that an expansion shares primary AND secondary with its spelled-out form.
      The `/` carries CASE_NEUTRAL_LIG instead, which suffices since every
      fraction has one. 5 new unit tests + 6 CLI tests. (2026-08-01 02:42 EDT)

- [x] **(c) `--roman`.** Whole-token Roman numerals ordered by VALUE (VII < IX).
      Canonical validation is parse-then-re-render, which is the canonical
      grammar without writing the grammar: IIII renders as IV, IM renders as MI,
      CIVIC parses to 205 rendering CCV, so all are rejected. Whole-token +
      uniform-case rules reject CIVIL, DID, MIL, LID and Mix. MIX is genuinely
      1009, which is why the flag is opt-in. Unicode numeral chars U+2160..2180
      route through phase (b) first, so only ASCII IVXLCDM is ever parsed.
      BUG found and fixed during this: on a failed parse the ENTIRE letter run
      must be consumed — emitting one character and looping let the check
      re-enter mid-word and match a trailing suffix, so CIVIL ended with the
      number 50 and CIVIC with 100, inverting them. 7 new unit tests + 11 CLI
      tests. (2026-08-01 03:00 EDT)

- [x] Quantified the --roman ambiguity against an 89,217-entry dictionary and
      pinned the result as a set-based test (Peter asked whether requiring
      "final reduced form" reduces ambiguity — it does, and it was already the
      behavior). 149 entries are built only from IVXLCDM; the canonical rule
      rejects 52 of them, i.e. nearly every multi-letter English word. Of the 97
      survivors, 83 are genuine numerals and 14 are bare single letters, leaving
      exactly five real-word collisions: CV DI div MD mix. Peter chose to KEEP
      single letters as numerals so chapter lists starting at I still work.
      Mutation testing found a real gap here: the uniform-case rule was
      untested, because every word in the first list was already rejected by the
      CANONICAL rule. Added mixed-case discriminators (Di, Md, Cl, Cm, Li, Ci,
      Cd, Dix — each canonical when uppercased) plus the all-caps counterpart of
      each, so the pair is discriminating rather than vacuous. Both rules now
      mutation-verified. (2026-08-02 10:40 EDT)

- [x] **Mechatron webhook** — already provisioned and working; the PLAN item was
      stale. Every pushed commit builds green (53d2fe3 in 75s). Badge matches the
      canonical snippet. Removed a lingering Garnix mention from flake.nix.
      (2026-08-02 10:35 EDT)
- [x] **Allocation-free compare.** compareAlloc now builds both keys in an 8 KiB
      stack scratch via FixedBufferAllocator, falling back to the heap only when
      a key outgrows it. Proven allocation-free with std.testing.FailingAllocator
      set to permit ZERO allocations, rather than asserted. Deliberately a
      scratch ALLOCATOR rather than a hand-written streaming comparator, so both
      paths still run through the one key builder and RULES.md #3 stays true BY
      CONSTRUCTION. HONEST RESULT: no measurable speedup (hyperfine, 400k
      strcoll8 calls: 218.8ms before vs 227.7ms after, overlapping ranges) —
      key construction dominates, so the win is the property, not throughput.
      Early-exit streaming is where real speed would come from, and it would cost
      the by-construction invariant. (2026-08-02 10:40 EDT)
- [x] **`./fuzz`** — property fuzzer over 8 option sets and 3 input shapes.
      Mutation testing of the FUZZER ITSELF found it initially near-vacuous:
      memcmp is a total order over any bytes, so reflexivity, antisymmetry and
      transitivity hold no matter what the key builder emits, and key-order ==
      compare-order compares two paths through the same builder. Added properties
      that can actually fail — structural |L2|==|L3|, plus independent numeric,
      case-fold and expansion-adjacency oracles — and a digits-only input shape,
      without which the numeric oracle never fired. All three injected bugs now
      caught. 200k iterations = 1.7M property checks, clean.
      (2026-08-02 10:50 EDT)

Current test count: 242 passed, 0 failed (80 Zig unit + 162 CLI integration).

## Open follow-ups

- [ ] **Compatibility folding of LETTERS** (Peter's "what about other letter-like
      things?", 2026-07-31). Digits are done; the letter side remains. Fullwidth
      digits were one instance of a much larger, but BOUNDED and
      already-standardized, family: Unicode's compatibility
      decomposition (NFKD/NFKC, `UnicodeData.txt` field 5). It is a deterministic
      TABLE, not a dictionary, so it fits the project thesis — unlike CJK.
      The family, roughly in value order:
      - **Fullwidth/Halfwidth Forms** U+FF00–FFEF (~225): fullwidth ASCII →
        ASCII, halfwidth katakana → katakana. Cheapest, highest value.
      - **Mathematical Alphanumeric Symbols** U+1D400–1D7FF: bold/italic/script/
        fraktur/double-struck/sans/monospace letters AND digits (𝟎-𝟿). ~1000
        code points but ALGORITHMIC — contiguous 26/26/10 runs with a handful of
        holes (the letterlike-symbol borrowings), so it is arithmetic plus a
        small exception table, not a big table.
      - **Enclosed Alphanumerics** U+2460–24FF (①, Ⓐ), **Roman numerals**
        U+2160–217F (Ⅷ), **super/subscripts** U+2070–209F (², ₃),
        **Letterlike Symbols** U+2100–214F (ℂ, ℌ, №), vulgar fractions (½).
        Small tables each.
      Design notes when this is picked up: (a) fold at the PRIMARY level with a
      TERTIARY distinction, exactly like the existing ligature expansions, so Ⓐ
      sorts with A without being identical to it; (b) several are EXPANSIONS
      (½ → 1⁄2, ™ → TM, Ⅷ → VIII), so the existing `foldExpansion` mechanism must
      grow past 2 letters; (c) **the numeric scanner is the real work** — it
      currently tests raw bytes (`b >= '0' and b <= '9'`), so fullwidth digits
      would have to be folded BEFORE the digit-run scan to participate in
      natural-numeric ordering. That is a change to the hot loop, not just a new
      table. Recommend shipping the fullwidth block first behind the same
      opt-in-free default, and deferring the rest.
- [ ] Early-exit streaming comparator for strcoll8. The allocation is already
      gone; the remaining win is not building whole keys when the strings differ
      in the first element. Cost to weigh: it duplicates the key-building logic,
      demoting RULES.md #3 from true-by-construction to true-by-testing.

## Deferred (future, noted in README Limits)

- [ ] i18n ENFORCE phase: all 50 locales, compile/test enforcement, bilingual
      errors, RTL handling, alias-collision comptime guard. Flip when the CLI
      surface stabilizes (see the i18n skill checklist).
- [ ] Full Unicode normalization: fold DECOMPOSED combining-mark sequences to
      equal precomposed forms (v1 folds only precomposed Latin).
- [ ] Broaden diacritic coverage beyond Latin-1 + common Latin Extended-A.
- [ ] Wire the reserved option bits (`RCOL_NUMERIC`,
      `RCOL_CASE_SENSITIVE`) to actually toggle behavior.
- [ ] Optional locale tailoring: a real `rcol_open_locale`. (This is the
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
