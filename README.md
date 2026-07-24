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
2. **Natural numeric runs.** `file2 < file10` (digit runs compare as numbers).
3. **Case-insensitive base letters.** `apple` and `Apple` are adjacent, not
   split into "all-uppercase-then-all-lowercase".
4. **Diacritics as a secondary tie-break.** `café` sorts near `cafe`
   (base letter `e`), *not* dead-last like raw code points: `café < cafz`.
5. **Case as the final tie-break.** lowercase before uppercase.
6. **NFC-aware for common precomposed Latin accents** (v1 subset — see Limits).
7. **No OS locale, ever.** Reproducible everywhere.
8. **Code-point fallback** (`--code-point`) == pure UTF-8 byte order.

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

- Diacritic folding covers Latin-1 Supplement + a common Latin Extended-A
  subset. Unknown code points degrade gracefully to code-point order (sorted
  after known letters).
- NFC handling covers common **precomposed** Latin accents; **decomposed**
  combining-mark sequences are not yet folded (the combining mark is treated as
  its own "other" element). Full normalization is deferred.
- `strcoll8` allocates temporary keys per call; the performance model is
  "precompute a sort key once, compare many". SIMD/streaming compare is deferred.

## Naming

The CLI binary is provisionally named **`collate`** — a single clean word. It can
be renamed without touching the library (the library symbols are
`collation_mf_*`).

## License

MIT — see [LICENSE](LICENSE).
