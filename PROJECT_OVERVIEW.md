---
purpose: Ultimate goals and terminology for collation_mf_do_you_speak_it
audience: both
maintained_by: agent
---

# collation_mf_do_you_speak_it — Project Overview

## The one-sentence goal

A small, FAST, OPINIONATED, cross-platform, REPRODUCIBLE string-collation /
sorting library that ships its own versioned ordering data and **ignores the OS
locale entirely** — because that is the only way to get byte-for-byte identical
sort results on glibc, musl, macOS, and Windows.

## Why this exists

- **glibc `strcoll` is not reproducible.** Its locale collation tables change
  across glibc versions, so the "same" sort produces different output on
  different distros/years.
- **musl has no locale collation at all** — it falls back to code-point order.
- **ICU is correct but heavy** — a large dependency to vendor for "sort these
  lines the way a human expects."
- **`rg` / `fd` / `eza` punt to code-point order**, which puts `Z` before `a`
  and every accented letter after `z`.

This library picks a single, opinionated, documented order, ships it as
versioned data compiled into the binary, and guarantees the same result
everywhere. If you want the raw escape hatch, `--code-point` gives you exact
`LC_ALL=C sort` order.

## Architecture (hexagonal / ports-and-adapters)

```
any consumer ──► C FFI (collation_mf_*) ──► pure Zig core (no I/O)
                     ▲
              C CLI `collate` dogfoods the same FFI
```

- **Pure Zig core** (`src/collation.zig`): all logic, no I/O. Builds sort keys.
- **C FFI** (`src/lib.zig` + `include/collation_mf_do_you_speak_it.h`): the real
  public API, modeled on ICU4C's `ucol_*` surface but UTF-8-native.
- **C CLI** (`cli/main.c`): the `collate` command, which calls *through* the FFI
  (not the Zig core directly) so the FFI boundary is exercised.

## Terminology

- **Sort key** (a.k.a. collation key / weight string): a binary string derived
  from an input such that plain `memcmp` of two sort keys reproduces the desired
  comparison order. Computed once, compared many. Mirrors ICU `ucol_getSortKey`.
- **House style**: the default opinionated order (structural-first, natural
  numeric, case-insensitive base, diacritic secondary, case tertiary).
- **Structural-first**: whitespace and punctuation sort BEFORE alphanumerics and
  are NOT ignored (the deliberate deviation from the Unicode Collation
  Algorithm, which makes punctuation ignorable). Yields "space before letters"
  and "shorter-prefix-before-longer".
- **Code-point mode**: the escape hatch (`COLLATION_MF_CODE_POINT`) = pure UTF-8
  byte order = `LC_ALL=C sort`.
- **Collation element**: one unit of comparison — a folded letter, a digit run,
  a whitespace char, a punctuation char, or an "other" code point.
- **Level (primary/secondary/tertiary)**: L1 = structural class + base letter;
  L2 = diacritics; L3 = case. Compared in that priority order.

## Naming conventions

- Zig package/module/static-lib: `collation_mf_do_you_speak_it`
- C FFI symbol prefix: `collation_mf_`
- C header: `include/collation_mf_do_you_speak_it.h`
- CLI binary (hyphenated): `collate` (provisional — see README for rename note)
- Default git branch: `yolo`
