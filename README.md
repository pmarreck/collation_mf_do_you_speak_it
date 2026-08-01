# collation_mf_do_you_speak_it

[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Fcollation_mf_do_you_speak_it.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

A small, **fast**, **opinionated**, cross-platform, **reproducible** string
collation / sorting library that ships its own versioned ordering and **ignores
the OS locale entirely**.

> Collation, motherf***er — do you speak it?

## Why

`sort`, `rg`, `fd`, and friends give you locale collation that is either
non-reproducible (glibc's tables change across versions), absent (musl falls
back to raw code points), or heavy (ICU). This library picks **one** opinionated,
documented order, compiles it in as versioned data, and produces **byte-for-byte
identical** results on glibc, musl, macOS, and Windows.

There is an escape hatch: `--code-point` gives you exact `LC_ALL=C sort` order.

## The opinionated house style (the default)

In priority order:

1. **Structural-first.** `whitespace < punctuation < digits < letters`.
   Whitespace and punctuation are significant and sort *before* alphanumerics
   (this is the deliberate deviation from the Unicode Collation Algorithm).
   So: `thing < "thing " < thing2 < thingthing`, and `"test with spaces" < test1`.
   *Spaces before letters. COME ON.*
2. **Natural numeric runs, arbitrary precision.** `file2 < file10` — digit runs
   compare as numbers, with **no cap on digit count**. Two 10,000-digit numbers
   order correctly. A leading `-` before digits is a **minus sign**
   (`-10 < -5 < 0`), but a `-` anywhere else stays a separator, so
   `peter-3 < peter-4` and ISO dates are unharmed. Dots are separators by default
   (`1.9 < 1.10`, version semantics); `-d`/`--decimal[=SEP]` declares decimal
   input, which absorbs digit-group separators between digits — so
   `999,999.00 < 1,000,000.00`, and **the same values sort into the same order
   whether written `1,000.00`, `1.000,00`, `1'000.00`, or `1 000.00`**.
   Absorption is group-size agnostic, so Indian 2-2-3 and Chinese 4-grouping work.
   Full detail and the complete list of caveats:
   **[docs/NUMERIC.md](docs/NUMERIC.md)**.
3. **Case-insensitive base letters.** `apple` and `Apple` are adjacent, not
   split into "all-uppercase-then-all-lowercase".
4. **Diacritics as a secondary tie-break.** `café` sorts near `cafe`
   (base letter `e`), *not* dead-last like raw code points: `café < cafz`.
5. **Case as the final tie-break.** lowercase before uppercase.
6. **Ligatures expand.** `ß`→`ss`, `œ`→`oe`, `æ`→`ae`, `ĳ`→`ij`, so `straße`
   lands next to `strasse` and `cœur` next to `coeur` instead of after every
   letter. The two stay distinguishable at the tertiary level, so the order
   remains total.
7. **NFC-aware for common precomposed Latin accents** (v1 subset — see Limits).
8. **No OS locale, ever.** Reproducible everywhere.
9. **Code-point fallback** (`--code-point`) == pure UTF-8 byte order.

## Build & test

```sh
./build          # ReleaseFast via `nix build`; installs to zig-out/bin/collate
./test           # Zig unit tests + CLI integration tests; exit code = # failures
./build --debug  # local debug build via bare `zig build`
```

Native Linux builds are fully static (musl), so the binary runs anywhere.

## CLI

```sh
collate [OPTIONS] [FILE]      # sorts lines from FILE (or stdin) to stdout

  -t, --field-separator <SEP>  Split each line on SEP (default: whole line)
  -k, --key <N>                Sort by the 1-based Nth field; ties -> whole line
  -c, --code-point             Pure UTF-8 byte order (== LC_ALL=C sort)
  -d, --decimal[=SEP]          Declare DECIMAL input; SEP is the decimal mark,
                               '.' (default) or ','. Digit-group separators are
                               then absorbed (999,999.00 < 1,000,000.00)
  -s, --sci, --scientific[=SEP]  Order by value with exponents (2e5 < 1e10);
                               plain numbers normalize as exponent 0
  -n, --num, --numeric[=SEP]   Both -d and -s
      --version-sort           Explicit form of the default dot handling
  -h, --help                   Show help
      --about                  One-line version + platform
      --version                Library version
      --lang <code>            UI language for --help/--about (e.g. en, de)
```

`FILE` may be `-` or `@stdin` for standard input (the default).

```sh
printf 'file10\nfile2\nApple\napple\n' | collate
# apple
# Apple
# file2
# file10
```

### Field sorting (`-t` / `-k`)

Sort by a chosen field, like `sort -t -k`. The separator may be multi-character;
a missing field sorts as empty. `COLLATE_FIELD_SEP` sets a default separator
(overridden by `-t`); a separator with no `-k` sorts by field 1.

```sh
printf 'a:3\nb:1\nc:2\n' | collate -t: -k2
# b:1
# c:2
# a:3
```

### Language (`--lang`, prepare-phase i18n)

`--help`/`--about` are localizable. Precedence: `--lang <code>` overrides
`COLLATION_MF_LANG`, which overrides `LANG`/`LC_*`; English is the default and
fallback. Today only `en` and a `de` demonstration locale ship (full coverage is
future work). Localized aliases: `--hilfe` (German help), `--sprache` (= `--lang`).

## C FFI (the real public API)

The C surface mirrors ICU4C's `ucol_*` collator API, but is UTF-8-native
(byte string + length, like `ucol_strcollUTF8`). See
[`include/collation_mf_do_you_speak_it.h`](include/collation_mf_do_you_speak_it.h).

```c
collation_mf_collator *c = collation_mf_open(0); /* 0 = house style */
int r = collation_mf_strcoll8(c, a, alen, b, blen);      /* -1 / 0 / +1 */
size_t n = collation_mf_get_sort_key(c, s, slen, out, cap); /* memcmp == strcoll8 */
collation_mf_close(c);
```

Plus POSIX-shaped drop-ins: `collation_mf_strcoll(a, b)` and
`collation_mf_strxfrm(dst, src, n)`.

## Benchmarks

Run `./bm` (uses `hyperfine` from the dev shell; logs to
`bench/<machine-id>.ndjson`). It compares `collate` against independent oracles
and runs a machine-independent scaling gate.

Measured — 50,000 realistic mixed lines, AMD Threadripper 3990X, hyperfine median:

| contestant | median | vs `collate` (house) |
|---|--:|--:|
| `sort` (`LC_ALL=C`, byte order) | 21.96 ms | **0.41×** (faster) |
| `collate --code-point` | 39.19 ms | 0.73× |
| `collate` (house style) | 53.46 ms | 1.00× |
| glibc `strcoll` (`en_US.UTF-8`) | 78.77 ms | 1.47× (collate faster) |
| `sort` (`en_US.UTF-8`) | 86.30 ms | 1.61× (collate faster) |
| ICU `ucol_getSortKey` (`en_US`) | *see `./bm`* | — |

**Honest verdict:** `collate` is **not** faster than coreutils' byte sort
(`LC_ALL=C sort`) — that's a mergesort doing trivial `memcmp`, and `collate`
does more work (multi-level keys). But `collate`'s opinionated house style is
**~1.5× faster than glibc locale collation** *and* reproducible across
glibc/musl/macOS/Windows, which locale collation is not. Use `--code-point` when
you want raw byte order and it's still within ~1.8× of `sort -C`.

**Scaling gate:** the sort path is `O(n log n)`; the gate runs it at N, 2N, 4N,
8N and fails on a super-linear (≥ 3×-per-doubling) regression. Measured ratios:
1.80 / 2.04 / 2.10 — clean `O(n log n)`.

## Architecture

Pure Zig core (no I/O) → C FFI (`collation_mf_*`) → C CLI that dogfoods the FFI.
See [PROJECT_OVERVIEW.md](PROJECT_OVERVIEW.md) and [RULES.md](RULES.md).

## Limits (v1)

**CJK is not covered — out of scope for now.** Chinese, Japanese, and Korean text
falls into `CLASS_OTHER` and sorts in **code-point order**: reproducible,
deterministic, and non-corrupting, but *not* linguistically ordered. This is a
deliberate boundary, not an oversight. Correct CJK collation needs **dictionaries**,
not tables:

- **Chinese** sorts by pronunciation (pinyin), which Han characters do not encode.
  A Han→reading map is ~40k entries, and it still is not enough because of
  polyphones (行 = *xíng* or *háng*), whose resolution needs word segmentation.
- **Japanese** sorts by reading (*yomi*), which is genuinely underdetermined —
  東 is *higashi* alone but *tō* in 東京, and surname readings are ambiguous even
  to humans. Even ICU punts, ordering kana properly and leaving kanji in a fixed
  Unihan order.
- **Korean** is the exception: hangul decomposes algorithmically and its
  code-point order already *is* dictionary order, so pure-hangul text is correct
  today by construction.

**The escape hatch, which needs no dictionary in this binary:** supply the reading
as a separate column and sort on it with `-t`/`-k`. That is what Japanese systems
actually do — it is why every Japanese form has a furigana field. Given
`東京<TAB>とうきょう`, `collate -t$'\t' -k2` yields correct Japanese order.

**One tailoring, not many.** The house style is a single global ordering, closest
to Unicode's DUCET **root** / Western-European default. That makes it *native*
for the Romance languages — accent-as-secondary is exactly the French, Spanish,
Italian, Portuguese, and Catalan rule — and correct for German *dictionary*
order. It is deliberately **non-native** for languages that treat accented forms
as distinct letters at the primary level:

| language | wants | we give |
|---|---|---|
| Swedish, Finnish | `å ä ö` as letters after `z` | folded to `a`/`o` |
| Danish, Norwegian | `æ ø å` as letters after `z` | `æ`→`ae`, `ø`→`o` |
| Czech, Slovak, Polish, Croatian | `č ř š ž` etc. as separate letters | folded to base |
| Hungarian | `cs dz dzs gy ly ny sz ty zs` as letters | not contracted |
| Estonian, Latvian, Lithuanian | reordered alphabets (`z` mid-alphabet in `et`) | base order |
| Turkish | dotless `ı` distinct from `i` | `ı` uncovered entirely |
| Spanish | `ñ` a letter after `n` | folded to base `n` |
| Canadian French (`fr-CA`) | accents compared *backwards* | forward |

This is a consequence of RULES.md #2 (never consult the OS locale), not an
oversight — one linear order cannot satisfy Swedish and German simultaneously.
Per-locale tailoring is the deferred fix. Note that broadening `æ`→`ae` in v1.1
*removed* an accidental correctness for Danish/Norwegian, where `æ` previously
landed after `z` by virtue of being unrecognized.

- Latin coverage is complete for French, Spanish, Italian, Portuguese, Catalan,
  Romanian, German, and Dutch (verified as a set, both directions, by
  `tests/integration/latin_coverage.sh`). Icelandic `ð`/`þ` and the Nordic
  `ø`/`å`-as-letters are **not** covered. Unknown code points degrade gracefully
  to code-point order (sorted after known letters).
- NFC handling covers common **precomposed** Latin accents; **decomposed**
  combining-mark sequences are not yet folded (the combining mark is treated as
  its own "other" element). Full normalization is deferred.
- `strcoll8` allocates temporary keys per call; the performance model is
  "precompute a sort key once, compare many". SIMD/streaming compare is deferred.
- **Numeric caveats are enumerated in [docs/NUMERIC.md](docs/NUMERIC.md)** — in
  short: leading zeros are invisible (`007` == `7`), thousands separators and
  exponent notation are not understood, an explicit `+` is not a sign, a sign is
  only recognized at the start of the collated string (use `-t`/`-k` to make a
  number a field), and digits must be ASCII.

## Naming

The CLI binary is provisionally named **`collate`** — a single clean word. It can
be renamed without touching the library (the library symbols are
`collation_mf_*`).

## License

MIT — see [LICENSE](LICENSE).
