# Grok Feedback — romantic_collation

**Date:** 2026-08-13 EDT
**Reviewer:** Grok (deep-code-review, 13 dimensions)
**HEAD:** `5f4ca054105e17e9400fde695cdf5fe93a8f6912`
**Scope:** Full tree at this commit. Independent of `CODE_REVIEW.md` (2026-08-05).

## Verdict

The August 5 criticals stay dead. I re-ran the two originally failing cases against `zig-out/bin/collate`:

```text
printf -- '-５\n-10\n-2\n' | collate          # -10 < -５ < -2
printf '0.009\n0.0０1\n' | collate --scientific  # 0.0０1 < 0.009
```

Code-point keys now include the promised trailing NUL (`src/collation.zig:1027-1031`, pinned by `src/lib.zig:168-177`).

What is left is smaller, but some of it is still a wrong answer on a documented path. I reproduced every WARNING below with the built CLI except the OOM contract (that one is by reading `src/lib.zig` + `cli/main.c`; you cannot force Zig-heap failure from the C side today).

| Severity | Count |
|---|--:|
| CRITICAL | 0 |
| WARNING | 8 |
| ADVISORY | 9 |

Dimensions 3 (futile tests), 7 (algorithmic class), 9 (language features), and 13 (database) did not produce a standalone WARNING. `src/collation.zig` should stay one file. Key construction is Θ(L); CLI sort is decorate-sort-undecorate.

## Do these first

1. Make `--version-sort` clear `RCOL_SCIENTIFIC` as well as `RCOL_DECIMAL`. One line, one CLI test, and the documented "later args win" rule starts matching reality.
2. Teach `scanExponent` to use `digitAt`. Folded digits are advertised; `1e５` currently is not 100000.
3. Treat `rcol_get_sort_key(...) == 0` as failure in `cmd_sort`. A successful key is never length 0.
4. Put `./test` (or the eight `tests/integration/*.sh` scripts) on the Mechatron `checks.test` derivation. CI currently greens on Zig unit tests only.

---

## Warnings

### `cli/main.c:915` — `--version-sort` does not undo `-n` or `-s`

**Dimension:** 1. Incomplete / inconsistent functionality.

`--version-sort` exists so a later argument can restore default dotted-number order. It only clears `RCOL_DECIMAL`. `-s`/`-n` leave `RCOL_SCIENTIFIC` set, and `sortKeyAlloc` treats scientific as decimal-dot mode (`src/collation.zig:1048-1050`: `decimal = OPT_DECIMAL != 0 or sci`).

Reproduced:

```text
printf '1.10\n1.9\n' | collate                 # 1.9 < 1.10   (default)
printf '1.10\n1.9\n' | collate -d --version-sort  # 1.9 < 1.10   (tested)
printf '1.10\n1.9\n' | collate -n --version-sort  # 1.10 < 1.9   (broken)
printf '1.10\n1.9\n' | collate -s --version-sort  # 1.10 < 1.9   (broken)
```

The only existing test is `-d then --version-sort wins` (`tests/integration/numeric_sort.sh:121`). Clear `RCOL_SCIENTIFIC` too, and add `-n`/`-s` counterparts.

### `src/collation.zig:806-821` — scientific exponents are still ASCII-only

**Dimension:** 1 and 2. Folded-digit feature is incomplete.

`digitAt` folds fullwidth and Mathematical Alphanumeric digits in mantissas, fractions, and signed runs. `scanExponent` still requires `s[j] >= '0' && s[j] <= '9'`. The August 5 sweep listed the loops it converted; this one was not on the list.

Reproduced:

```text
printf '2e4\n1e5\n'  | collate --scientific   # 2e4 < 1e5   (values 20000 < 100000)
printf '2e4\n1e５\n' | collate --scientific   # 1e５ < 2e4   (parsed as 1, then e, then 5)
```

`１e5` (folded mantissa, ASCII exponent) already works. Route the exponent through `digitAt` the same way. Tests to add: `1e５`, `1E５`, `2e４ < 1e5`, and a signed ` -1e５`.

### `src/collation.zig:1101` — `--roman` treats every byte `>= 0x80` as “not a token boundary”

**Dimension:** 1. Open item from `CODE_REVIEW.md`; still true.

The comment says a following non-ASCII *letter* disqualifies the run (`MIXé`). The code is `j >= s.len or s[j] < 0x80`. ASCII punctuation works; Unicode punctuation and symbols do not.

Reproduced:

```text
printf 'IX.\nVII.\n'   | collate --roman   # VII. < IX.     (values 7 < 9)
printf 'IX™\nVII™\n'   | collate --roman   # IX™ < VII™     (letters I < V)
printf 'IX—\nVII—\n'   | collate --roman   # IX— < VII—     (same)
```

`emitExpansion` asks `romanValue` of the replacement in isolation, so `Ⅸ™` *is* the number 9 while `IX™` is letters. Decode the following scalar; reject `foldLetter` hits; accept punctuation, symbols, digits, and end-of-string. Keep `MIXé` as the safety regression.

This is also still the open product call on `PLAN.md` (“Unicode-symbol boundaries for `--roman`”). The current code does not match its own comment either way.

### `src/lib.zig:61-93` — allocation failure and a NULL collator become a successful result

**Dimension:** 11 and 12. Open item from `CODE_REVIEW.md`; still true.

| Call | On OOM / NULL coll |
|---|---|
| `rcol_strcoll8` / `rcol_strcoll` | `0` (`RCOL_EQUAL`) |
| `rcol_get_sort_key` / `rcol_strxfrm` | length `0` |

A successful house-style key is at least `SEP SEP TERM` (3 bytes). A successful code-point key is `input + NUL` (at least 1). Length 0 is never success. The header documents only `-1/0/+1` and a length.

`compareAlloc` stays off the heap for ordinary lines (8 KiB scratch, proven by `collation.zig:1460`). The catch is live for long lines and huge digit runs. Under mixed success, `rcol_strcoll8` can say equal while `memcmp` of the two `rcol_get_sort_key` results does not. That is a hole in RULES.md #3.

Decide the API (checked `rcol_strcoll8_r`, `INT_MIN`, or `(size_t)-1` + `errno`). Until then, document “OOM and NULL collator return 0” in the header. Add a failing-allocator test below the C boundary.

### `cli/main.c:776-791` — the CLI stores a 0-length key and can print a wrong order with exit 0

**Dimension:** 12.

`cmd_sort` already fails loud on `malloc`/`realloc`/`rcol_open` failure. It does not look at `rcol_get_sort_key` returning 0. Those rows sort to the front (`cmp_rows` memcmp of 0 bytes, then shorter-key-first). If every FFI call fails, the raw-line tie-break makes the tool `LC_ALL=C sort` and still exit 0.

Reject `need == 0` the same way as `malloc` failure. No ABI change. Empty input is already handled before any key is built (`cli/main.c:733-736`).

### `flake.nix:52-55` — Mechatron `checks.test` never runs the CLI suite

**Dimension:** 2.

`.mechatron-prime/targets` builds `checks.x86_64-linux.test`. That derivation is `timeout 600 zig build test`. Local `./test` also runs every `tests/integration/*.sh` (249 CLI checks at the last PLAN count). A C-side regression (`--version-sort`, field extract, i18n catalogs, `collate` arg parse) can ship CI-green.

The Nix check also has no `bc` / `coreutils`, which `numeric_sort.sh` and `code_point_differential.sh` need. Point `checks.test` at `./test`, or at least at the integration scripts after building `collate`.

### `cli/main.c:799-802` — write errors are silent success

**Dimension:** 12.

`read_all` checks `ferror` on input. The write loop does not check `fwrite` / `fputc` / `fflush` / `ferror(stdout)`. A full disk or a closed stdout still exits 0 with a truncated stream. Check the write and exit 1.

### `include/romantic_collation.h:59-61` — `RCOL_DECIMAL_COMMA` is not ignored without `RCOL_DECIMAL`

**Dimension:** 1 and 11.

The header says the comma bit is “Ignored without DECIMAL.” `sortKeyAlloc` reads `OPT_DECIMAL_COMMA` on its own (`src/collation.zig:1051`). The CLI `--scientific=,` sets `RCOL_SCIENTIFIC | RCOL_DECIMAL_COMMA` and not `RCOL_DECIMAL` (`cli/main.c:879-891`). Reproduced: `1,5e3` under `--scientific=,` orders as 1500 (`1,5e3 < 2e3`), so the comma *is* the mantissa decimal mark. Grouping absorption still requires `RCOL_DECIMAL` (`absorb = OPT_DECIMAL != 0`), which is why `1.5` stays 1.5 under `--scientific=,` and becomes 15 under `--decimal=,`.

Fix the header sentence. The CLI SEP grammar is fine; the comment is what is wrong.

---

## Advisories

### `isSpace` and `groupSepLen` disagree on Unicode spaces

`src/collation.zig:479-484` vs `668-682`.

ASCII space and NBSP (U+00A0) are `CLASS_WS` (sort before letters). Thin space (U+2009) and narrow NBSP (U+202F) are `CLASS_OTHER` (sort after letters) unless `--decimal` absorbs them as group separators. Reproduced: a lone U+2009 sorts after `a`; a lone NBSP sorts before `a`. Under `-d`, `1\u2009000` *does* beat `999`. If those code points are “spaces” in the structural-first story, put them in `isSpace`. If they are only grouping marks, say so in `docs/NUMERIC.md`.

### `pushNumericPrimary` is a second length+digit encoder

`src/collation.zig:960-1004` vs `pushNumLength` + `countSigDigits` + `emitSigDigits`.

Signed, decimal, and scientific paths share the helpers. Default unsigned runs (and Roman-to-Arabic) reimplement the non-inverted half. This is the same class of duplication that produced the August 5 folded-negative defect. Collapse it. Pin that default-mode `"123"` and `OPT_DECIMAL` `"123"` emit the same L1 digit payload.

### Fuzzer still cannot catch the remaining folded-digit holes

`src/fuzz.zig:140-161` (ASCII-only numeric oracle), `203-214` (interesting strings sample UTF-8 bytes, not well-formed folded numbers), `108-115` (code-point keys skip the NUL hygiene check, with a stale comment that empty input yields an empty key). The August 5 NUL fix would not have been caught here. Extend the oracle or add a `folded_digits` shape.

### Finite tables are sampled, not exhausted

`compatExpand` has 63 rows; `expectExpands` pins 15. `℅` (`0x2105` → `"c/o"`) never goes through `expectExpands`. `foldLetter` is checked as “is this `CLASS_LETTER`?” for the declared Western-European set; ~40 Latin Extended-A rows (`Š š Ł ł Ø Å` …) never appear, and a swapped diacritic rank would still pass. Exhaust the tables, or generate the tests from the same data the switch uses.

### `rcol_strcoll` and `rcol_strxfrm` have no caller and no test

`src/lib.zig:85-105`. The CLI dogfoods `open` / `get_sort_key` / `close` / `version` only. `rcol_strxfrm`’s “length excludes NUL, force-terminate on truncation” contract is easy to get wrong. `rcol_get_sort_key` is also untested for `0 < cap < needed`.

### `RULES.md:68` is stale

It still says only `en` + a `de` demonstration locale exist. `cli/main.c` ships eight catalogs (`en de fr es it pt_br ca ro`). Update the sentence. PREPARE-phase status is otherwise correct.

### Dead `g_coll` and a stale `parseLeadingNumber` comment

`cli/main.c:650` / `752`: assigned, never read. `cmp_rows` only memcmp’s precomputed keys. The comment “used by qsort comparator” invites wiring a global back into the comparator. Delete it.

`src/collation.zig:69` still names `parseLeadingNumber`, which is gone. Point it at `pushLeadingNegative`.

### `Version.major` / `minor` / `patch` are unused

`src/lib.zig:20-25`. `rcol_version()` returns a separate `"0.1.0"` string. Drive the string from the triple, or drop the fields.

### `./bm` still never compares a new same-machine median to the last ndjson row

Open product call on `PLAN.md`. The scaling-ratio gate is present and is the right hard control for shape. A flat 2× constant-factor hit on `collate-house` still exits 0. Add the two-sided, wide, per-machine baseline when you want that secondary gate.

---

## Product-shaped improvements (not defects)

These are the places I would extend the tool, not bugs in what is already specified.

**CI should run the thing users run.** `./test` is the contract. `checks.test` should invoke it (with `bc` and `coreutils` in `nativeBuildInputs`).

**CRLF.** Files are opened `"rb"` and split on `\n` only. A Windows file keeps `\r` on every line. Mixed CRLF/LF is currently harmless for letter order (trailing `\r` is `CLASS_WS`) and ugly for last-field `-t` extracts. Strip a single trailing `\r` when splitting. stdin on Windows is still text-mode; set binary mode on stdin/stdout if you care about the Windows target in the 5-platform matrix.

**Common `sort(1)` verbs the CLI does not have.** `-r`/`--reverse`, `-u`/`--unique`, `-o`/`--output` (with `-` / `@stdout`). Later-args-win already exists as a convention, so `-r` is a cheap flag. Unique should key-compare, not raw-line-compare.

**Reserved bits.** `RCOL_NUMERIC` (disable natural runs) and `RCOL_CASE_SENSITIVE` are documented no-ops. CLI `-n`/`--numeric` is a *different* switch (`SCIENTIFIC|DECIMAL`). The name collision is the only trap. Wiring the reserved bits is already deferred on `PLAN.md`; when you do it, pick a CLI spelling that is not `--numeric`.

**`emitExpansion` is a second tokenizer.** `src/collation.zig:442-476`. Current replacements are plain ASCII by construction, so this is fine today. A future replacement that contains a space would emit `CLASS_PUNCT` instead of `CLASS_WS`. Either keep the “ASCII only” rule in the function’s contract, or call back into the main scanner.

**Invalid UTF-8.** House style degrades each bad byte to one `CLASS_OTHER` element and always advances. Total, deterministic, undocumented. One sentence in the header plus a test (`"a\xff" < "b"`, overlong `C0 80` ≠ `"\0"`) would lock the policy.

**Early-exit streaming compare.** Still the only remaining throughput idea that would matter. It would duplicate the builder and demote RULES.md #3 from true-by-construction to true-by-testing. I would not do it until a profile says key construction of *short* unequal strings is the cost. The CLI never calls `strcoll8`; it precomputes keys.

**Do not split `src/collation.zig`.** About 45% of the file is tests. `cli/main.c` is long because of eight help catalogs, not because `cmd_sort` is a god-function.

---

## Prior review, current status

| Aug 5 item | Status at `5f4ca05` |
|---|---|
| Folded digits on signed / fractional / scientific paths | Fixed. New hole: scientific *exponents* (`1e５`). |
| Code-point keys missing NUL | Fixed. |
| Folded-digit tests omitted those modes | Fixed for the cases above; exponents, `+５`, `1,０００`, `００７` still missing. |
| `--roman` Unicode punctuation boundary | Still open. Comment and code still disagree. |
| `rcol_strcoll8` OOM → equality | Still open. Header still silent. |
| Header / README / NUMERIC.md contradictions | Fixed. Remaining stale line is `RULES.md:68` (locales). |
| Unreachable `parseLeadingNumber` decimal branch | Removed. Stale comment remains at `CLASS_NEG`. |
| `./bm` same-machine baseline | Still open. Scaling gate is the only hard check. |
