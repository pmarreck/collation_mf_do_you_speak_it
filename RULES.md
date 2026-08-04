---
purpose: Invariants that must always hold for romantic_collation
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

3. **Sort-key order == compare order.** `rcol_get_sort_key` must produce
   a key whose `memcmp`/lexicographic order is identical to
   `rcol_strcoll8` for the same collator. This is enforced by
   construction (compare is defined via the key builder) and property-tested
   over random strings. Never let them diverge.

4. **Sort keys are C-safe.** House-style keys are NUL-terminated and contain no
   interior NUL byte, so C callers may compare with `strcmp`/`memcmp`.

5. **Code-point mode == `LC_ALL=C sort`.** With `RCOL_CODE_POINT`, the
   order is exactly pure UTF-8 byte order. This is the escape hatch and the
   simplest correct baseline; it is differentially tested against coreutils
   `LC_ALL=C sort`.

## Architecture invariants

6. **Pure core, no I/O.** `src/collation.zig` performs no I/O and reads no
   globals. All I/O lives in the CLI.

7. **The CLI dogfoods the FFI.** `cli/main.c` calls the `rcol_*` C
   symbols; it never bypasses them. (It is written in C precisely so it *cannot*
   import the Zig core directly — the bypass is inexpressible.)

## Process invariants

8. **TDD.** No behavior change without a failing test first. Every commit is a
   green state (`./test` passes) before it is made.
9. **Clean test output.** Expected stderr is captured and asserted, never leaked
   to the console during a passing run.

## Internationalization

- **Status: `enabled` (PREPARE phase).** Decision owner: Peter Marreck, via the
  coordinator, 2026-07-24 EST. Scope: the `collate` CLI's user-facing
  `--help`/`--about` strings.
- Rationale: the CLI is intended to be cross-platform, professional, UTF-8-native
  tooling; groundwork now (typed message table, `--lang` + env precedence,
  localized-alias hook, English default/fallback) avoids a retrofit later.
- PREPARE phase means: infrastructure exists and English is complete; other
  locales are non-fatal (missing app-requested locale WARNs and falls back to
  English). Only `en` + a `de` demonstration locale exist today. Full 50-locale
  coverage and compile/test enforcement are DEFERRED to the enforce phase (when
  the CLI surface stabilizes). See the i18n skill for the enforce checklist.
- Precedence (highest first): `--lang <code>` / localized alias → `ROMANTIC_COLLATION_LANG`
  → `LC_ALL` → `LC_MESSAGES` → `LANG` → English.
