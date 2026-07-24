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

Current test count: 63 passed, 0 failed (15 Zig unit + 48 CLI integration).

## Open follow-ups

- [ ] Mechatron webhook provisioning from Thelio (`provision-mechatron-webhooks`)
      — needs the host secret; see report if it required interactive sudo.
- [ ] `strcoll8` allocates two temp keys per call; add an allocation-free
      streaming level-by-level comparator for the common early-exit case.
- [ ] Numeric significant-digit length capped at 250 (byte-sized prefix);
      widen if a real corpus needs >250-digit numbers.

## Deferred (future, noted in README Limits)

- [ ] i18n ENFORCE phase: all 50 locales, compile/test enforcement, bilingual
      errors, RTL handling, alias-collision comptime guard. Flip when the CLI
      surface stabilizes (see the i18n skill checklist).
- [ ] Full Unicode normalization: fold DECOMPOSED combining-mark sequences to
      equal precomposed forms (v1 folds only precomposed Latin).
- [ ] Broaden diacritic coverage beyond Latin-1 + common Latin Extended-A.
- [ ] Wire the reserved option bits (`COLLATION_MF_NUMERIC`,
      `COLLATION_MF_CASE_SENSITIVE`) to actually toggle behavior.
- [ ] Optional locale tailoring: a real `collation_mf_open_locale`.
- [ ] SIMD sort-key generation for throughput.
- [ ] `./fuzz`: property-fuzz `sortKeyAlloc` — the sort-key-order ==
      compare-order invariant must never break on random bytes.
