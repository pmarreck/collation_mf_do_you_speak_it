---
purpose: Invariants that must always hold for collation_mf_do_you_speak_it
audience: agent
maintained_by: human
---

# RULES — do not violate without an explicit, documented reason

These are the load-bearing invariants of the project. They are control rules:
changing one changes the *product*, not just an implementation detail.

## Blessed invariants (the two that define the product)

1. **Structural-first ordering.** In house style, the primary comparison class
   order is `whitespace < punctuation < digits < letters`. Whitespace and
   punctuation are significant and sort BEFORE alphanumerics — they are NOT
   ignored (this is the deliberate deviation from the Unicode Collation
   Algorithm). "Spaces before letters, COME ON." Consequences that MUST hold:
   `thing < "thing " < thing2 < thingthing` and `"test with spaces" < test1`.

2. **No OS locale, ever.** The library reads nothing from the environment — no
   `LC_*`, no `LANG`, no glibc/ICU locale tables. Ordering comes only from the
   versioned, self-contained tables compiled into the binary. The output must be
   byte-for-byte reproducible on glibc, musl, macOS, and Windows.

## Correctness invariants

3. **Sort-key order == compare order.** `collation_mf_get_sort_key` must produce
   a key whose `memcmp`/lexicographic order is identical to
   `collation_mf_strcoll8` for the same collator. This is enforced by
   construction (compare is defined via the key builder) and property-tested
   over random strings. Never let them diverge.

4. **Sort keys are C-safe.** House-style keys are NUL-terminated and contain no
   interior NUL byte, so C callers may compare with `strcmp`/`memcmp`.

5. **Code-point mode == `LC_ALL=C sort`.** With `COLLATION_MF_CODE_POINT`, the
   order is exactly pure UTF-8 byte order. This is the escape hatch and the
   simplest correct baseline; it is differentially tested against coreutils
   `LC_ALL=C sort`.

## Architecture invariants

6. **Pure core, no I/O.** `src/collation.zig` performs no I/O and reads no
   globals. All I/O lives in the CLI.

7. **The CLI dogfoods the FFI.** `cli/main.c` calls the `collation_mf_*` C
   symbols; it never bypasses them. (It is written in C precisely so it *cannot*
   import the Zig core directly — the bypass is inexpressible.)

## Process invariants

8. **TDD.** No behavior change without a failing test first. Every commit is a
   green state (`./test` passes) before it is made.
9. **Clean test output.** Expected stderr is captured and asserted, never leaked
   to the console during a passing run.
