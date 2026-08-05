# Code Review -- romantic_collation

**Date:** 2026-08-05 EDT
**Reviewer:** Codex (independent checker)
**Scope:** Full codebase audit at `6b644c6`, across all 13 deep-review dimensions.

## Summary

- **CRITICAL:** 2
- **WARNING:** 4
- **ADVISORY:** 2

`./test` passed before this review. The default `./fuzz` run did not report a
failure. The failures below were reproduced through `zig-out/bin/collate`:

```text
# Incorrect: −5 sorted before −10.
printf '%s\n' '-５' '-10' '-2' | collate

# Incorrect: 0.009 sorted before 0.001.
printf '%s\n' '0.009' '0.0０1' | collate --scientific
```

## Implementation status (2026-08-05)

The two critical defects are fixed and covered by new unit, FFI, and CLI
regressions: folded digits now work in leading signed numbers and fractional
decimal/scientific paths, and every code-point key has its promised terminal
NUL. The stale public numeric documentation and the unreachable byte-oriented
leading-number path are also corrected. `./test` passes 247 checks after those
changes.

The remaining decisions are intentionally open: Unicode punctuation boundaries
for `--roman`, an allocation-failure channel for the C comparison API, and a
same-machine performance-history threshold for `./bm`.

## Critical Issues

### `src/collation.zig:838` -- Folded digits take byte-wise numeric paths

**Dimension:** 1. Inconsistent, incomplete, or undefined functionality.

`digitAt` correctly maps fullwidth and mathematical digits to values, but the
signed default path strips, counts, and emits raw bytes at
`src/collation.zig:904-951`. Scientific fractional normalization also advances
one byte at a time at `src/collation.zig:835-841`, and trailing-zero removal
checks only ASCII `0` at `src/collation.zig:683-685`.

This breaks the advertised folded-digit feature in several modes. For example,
default ordering produces `-５ < -10`, while scientific ordering produces
`0.009 < 0.0０1` and `0.0001 < 0.０`. The latter treats a folded zero as a
nonzero mantissa. Route every significant/leading/trailing-zero operation and
emission through code-point-aware digit helpers. Add deterministic tests for
fullwidth and mathematical digits in signed, decimal, scientific, zero, and
fractional cases.

### `src/collation.zig:1034` -- Code-point sort keys omit the promised NUL

**Dimension:** 10. Memory safety and resource leaks; 11. FFI boundary correctness.

The code-point branch returns an exact duplicate of the input, unlike the
house-style branch that ends in `TERM`. `rcol_get_sort_key` returns that buffer
unchanged at `src/lib.zig:67-81`, but the public header promises a length that
includes a trailing NUL and explicitly permits `strcmp` at
`include/romantic_collation.h:128-137`. A C caller that trusts that contract can
read past its allocated output buffer under `RCOL_CODE_POINT`.

Append a terminal NUL in code-point mode. That preserves byte-order comparison,
including prefix order, when callers compare the returned length. Document the
interior-NUL limitation for the explicit-length API, or encode such input if
`strcmp` support for embedded NUL is a required product property. Add a C-FFI
test that length-probes and copies a code-point key.

## Warnings

### `tests/integration/numeric_sort.sh:254` -- Folded-digit tests omit the broken modes

**Dimension:** 2. Inadequate test coverage.

The folded-digit section tests bare and embedded runs plus a single positive
integer in `-d` and `-s`. It does not test signed folded numbers, folded leading
or trailing fractional zeroes, or a mixed-width fractional mantissa. The unit
tests have the same gap. The fuzzer's independent numeric oracle is deliberately
ASCII-only (`src/fuzz.zig:140-160`), while its interesting-string generator
samples individual UTF-8 bytes (`src/fuzz.zig:203-214`), so it provides no
semantic oracle for well-formed folded-digit numbers. This allowed the critical
defect above through both the suite and the default fuzzer.

### `src/collation.zig:1103` -- Roman token boundary rejects Unicode punctuation

**Dimension:** 1. Inconsistent, incomplete, or undefined functionality.

The comment says that a following non-ASCII *letter* disqualifies a Roman token,
but `s[j] >= 0x80` rejects every non-ASCII scalar. Thus `--roman` orders `IX™`
before `VII™` and `IX—` before `VII—` as text, while ASCII `IX.` and `VII.` sort
by numeral value. Decode the following scalar and reject Unicode letters while
accepting punctuation and symbols as token boundaries. Preserve the `MIXé`
safety case in a regression test.

### `src/lib.zig:61` -- Allocation failure silently becomes equality

**Dimension:** 12. Error handling gaps.

`rcol_strcoll8` and `rcol_strcoll` catch every allocation error and return `0`.
That silently reports unrelated strings as equal, which can corrupt a caller's
sort or ordered index. The header documents only the three ordering results and
has no allocation-failure contract. Add a distinct error result or a checked API
that reports failure; if API compatibility requires the existing result, document
the behavior and expose an error channel. Test the heap-fallback failure with a
failing allocator below the C boundary.

### `include/romantic_collation.h:47` -- Public numeric documentation contradicts the implementation

**Dimension:** 8. Files without clear purpose.

The header and `docs/NUMERIC.md:117-122` say decimal parsing applies only to a
leading number. The implementation deliberately scans every number in decimal
mode (`src/collation.zig:1072-1092`), and the same document later says so.
`README.md:240-244` also still says leading zeroes tie by default, exponents are
unsupported, `+` is not a sign, and only ASCII digits work. All four claims are
obsolete. Correct the external API header, the conflicting numeric prose, and
the README limits section together.

## Advisory

### `src/collation.zig:892` -- Unreachable decimal branch duplicates numeric logic

**Dimension:** 5. Superfluous or duplicated functionality.

`parseLeadingNumber` is called only as `parseLeadingNumber(s, false)` at
`src/collation.zig:1066`. Its decimal parsing, `LeadingNum.frac`, and the
positive branch of `pushSignedDecimal` therefore cannot execute. This second,
byte-oriented numeric implementation drifted away from the code-point-aware
grouped-number pipeline and is the source of the folded negative defect. Reduce
the default signed path to the behavior it actually needs, or share the
code-point-aware numeric helpers rather than maintaining both implementations.

### `bm:160` -- Benchmark history is recorded but never compared

**Dimension:** 4. Fast test coverage.

`./bm` appends medians and scaling records, and correctly blocks an O(n²)-shaped
regression at `bm:165-211`. It never compares a new same-machine median with the
prior ndjson record, so the promised performance history cannot flag a large
constant-factor slowdown or unexpected speedup. Add a two-sided, deliberately
wide baseline gate for the house-style measurement, while retaining the existing
machine-independent scaling gate as the hard control.

## Dimension Coverage

1. **Inconsistent, incomplete, or undefined functionality:** two warnings and
   the folded-digit critical issue above.
2. **Inadequate test coverage:** missing folded signed/fraction coverage above.
3. **Futile test coverage:** no separate issue. The fuzzer explicitly identifies
   its algebraic checks as weak and pairs them with independent semantic oracles.
4. **Fast test coverage:** benchmark baseline comparison advisory above; no
   sleeps or timing-based correctness tests found.
5. **Superfluous or duplicated functionality:** unreachable decimal branch
   advisory above.
6. **Suboptimal, inconcise, or disorganized code:** no separate issue. The core,
   FFI, and CLI boundaries are coherent for this project.
7. **Algorithmic complexity:** no issue found. Key construction is linear in
   input bytes and CLI sorting is O(n log n); the scaling gate exercises that
   claim.
8. **Files without clear purpose:** public-documentation drift warning above.
9. **Not leveraging language features:** no material issue found. Zig cleanup
   uses `defer`/`errdefer`, and the FFI uses explicit slice lengths and sentinel
   types where applicable.
10. **Memory safety and resource leaks:** code-point key critical above. The
    stack-scratch/heap-fallback ownership in `compareAlloc` is otherwise sound.
11. **FFI boundary correctness:** code-point key critical above. The C CLI
    exercises the public header rather than bypassing it.
12. **Error handling gaps:** silent allocation-failure warning above.
13. **Database access patterns:** not applicable; the project has no database.
