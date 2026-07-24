---
purpose: Work plan and roadmap for collation_mf_do_you_speak_it
audience: agent
maintained_by: agent
---

# PLAN — collation_mf_do_you_speak_it

## Done

- [x] Phase 0 — scaffold (build.zig/zon, flake.nix, ./build, ./test, .gitignore,
      LICENSE, docs). `nix build` green; static-musl native binary that runs on
      NixOS. `collate --version/--about/--help` work. (2026-07-23 ~21:20 EST)
- [x] Phase 0.1 — static-musl native target fix so the binary runs on NixOS
      (dynamic-musl loader `/lib/ld-musl-*.so.1` is absent here). (2026-07-23)
- [x] Phase 1 — code-point fallback (`COLLATION_MF_CODE_POINT`): strcoll8 =
      raw byte order; sort_key = raw bytes. MFIC differential test vs
      `LC_ALL=C sort` over a 122-line corpus PASSES. (2026-07-23 ~21:26 EST)
- [x] Phase 2 — opinionated house style (structural-first, natural numeric,
      case-insensitive base, diacritic secondary, case tertiary). All required
      orderings asserted (unit + CLI integration). (2026-07-23 ~21:26 EST)
- [x] Phase 3 — CLI `collate`: stdin/`-`/`@stdin`/file, `--code-point`/`-c`,
      `-h`/`--help`/`--about`/`--version`, paths with spaces, error paths.
      Integration tests in `./test`. (2026-07-23 ~21:26 EST)
- [x] Invariant: `get_sort_key` memcmp order == `strcoll8` order — property
      test over 2000 random strings in both modes. (2026-07-23)

## Curiosity pokes / follow-ups

- [ ] Numeric significant-digit length is capped at 250 (byte-sized length
      prefix). Numbers with >250 significant digits misorder. Document / widen
      the prefix if any real corpus needs it.
- [ ] `strcoll8` allocates two temp keys per call. Add a streaming level-by-level
      comparator that avoids allocation for the common early-exit case.
- [ ] Distinct whitespace chars (tab vs space) currently collapse to equal keys
      (a legit collation equivalence). Revisit if a use case needs them split
      *without* violating "case is the final tie-break".

## Deferred (future, noted in README Limits)

- [ ] Full Unicode normalization: fold DECOMPOSED combining-mark sequences
      (`e` + U+0301) to equal the precomposed form. v1 only folds precomposed.
- [ ] Broaden diacritic coverage beyond Latin-1 + common Latin Extended-A.
- [ ] Optional locale tailoring: a real `collation_mf_open_locale`.
- [ ] Wire the reserved option bits (`COLLATION_MF_NUMERIC`,
      `COLLATION_MF_CASE_SENSITIVE`) to actually toggle behavior.
- [ ] SIMD sort-key generation for throughput.
- [ ] Benchmark suite: `./bm` + `bench/<machine-id>.ndjson` with the
      self-describing `_meta` header; scaling-ratio (O(n)) gate on the sort-key
      builder; hyperfine constant-factor gate.
- [ ] Fuzz `./fuzz`: feed random bytes to `sortKeyAlloc`; assert the
      sort-key-order == compare-order invariant never breaks (property fuzz).
- [ ] Create GitHub repo `pmarreck/collation_mf_do_you_speak_it` and push
      branch `yolo`; confirm Garnix `build` + `test` checks go green.
