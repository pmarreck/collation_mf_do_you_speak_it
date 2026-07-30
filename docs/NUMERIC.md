---
purpose: How numeric collation works in collation_mf_do_you_speak_it — the technique, what it buys, and exactly where it is wrong
audience: both
maintained_by: agent
---

# Numeric collation

How `collate` orders numbers, why, and — in full — where it does *not* do what
you might assume. Nothing here is aspirational; every claim and every caveat is
pinned by a test in `tests/integration/numeric_sort.sh` or `src/collation.zig`.

## The technique: a length-prefixed digit run

A maximal run of ASCII digits becomes **one collation element**, not a sequence
of characters. It is emitted into the primary level as:

| byte | meaning |
|---|---|
| `CLASS_DIGIT` (0x30) | structural class |
| `0x02 + N` | **N** = count of significant digits (leading zeros stripped) |
| `0x02 + d` each | the digits themselves |

The **length prefix** is the whole trick. For two base-10 numbers, the one with
fewer significant digits is smaller — that is just magnitude — so the length byte
decides most comparisons outright, and only on a tie do the digits compare, where
lexicographic *is* numeric for equal lengths.

```
word5  → … 0x30 0x03 0x07
word10 → … 0x30 0x04 0x03 0x02
                 ↑ memcmp stops here: 0x03 < 0x04
```

This lives in the **sort key**, not in a comparator, so plain `memcmp` reproduces
numeric order and the "compute a key once, compare many" model still holds.
Length-prefixing beats zero-padding because padding needs a maximum width chosen
up front and inflates every key; this costs one byte.

Same idea as ICU's numeric collation (CODAN) and the `sort -V` family.

## Arbitrary precision

The length prefix is **itself variable-length**, so there is no cap on how many
digits a run may carry. Beyond 250 significant digits it escalates:

```
0xFF  <how many base-254 length bytes follow>  <the length, big-endian>  <digits…>
```

Ordering holds at every step: the `0xFF` sigil exceeds every short-form length
byte (so every long number sorts after every short one — correct, since more
significant digits means a bigger number); a wider length-of-length beats a
narrower one; and equal-width lengths compare big-endian, which is numeric order.

The structure is borrowed from **[BLIP](https://github.com/pmarreck/BLIP)**
("Byte Length Integer Prefix") — escalating magnitude class in the header,
payload after, `memcmp`-ordered. Two deliberate divergences:

- **BLIP's encoding is not used verbatim.** Its payload bytes freely contain
  `0x00` and `0x01`, which are this format's `TERM` and `SEP`. That would violate
  RULES.md #4 (C-safe keys, no interior NUL) *and* break the shorter-prefix-first
  property, since `SEP` must be ordinally below all content. So this is a
  byte-range-restricted variant: every byte is ≥ `0x02`, and the sigil is
  harvested from the **top** of the range because ordering wants it above all
  content rather than in the middle.
- **The payload stays base-10-per-byte**, not base-254. Converting an
  arbitrary-precision decimal string to base-254 requires bignum division — O(n²)
  in the digit count — which would break the `O(n log n)` scaling gate. For a
  sort key, density is the wrong objective; **O(n) construction** is, because you
  build one key per line.

A note on BLIP's *sentinel space* (its 128 overlong patterns, free for type
tags): that trick does **not** transfer wholesale here. BLIP only needs its
sentinels to be **distinguishable**; a collation key needs its sentinels to be
**ordinally positioned**. Ordinal position cannot be harvested from redundancy —
it has to be carved out of the value range, which is why every content byte pays
the `+0x02` offset. The length-escalation sigil is the one case where the two
requirements coincide, and it is the one case where the trick applies.

## Signed numbers

A `-` is a **minus sign only when it starts the collated string**, and only when
a digit follows it. Anywhere else it is a separator.

```
-10 < -5 < -2 < 0 < 2 < 5 < 10        # signed
peter-3 < peter-4 < peter-10          # separator — natural numeric after it
2026-07-29 < 2026-08-01               # ISO dates unharmed
```

That rule is what makes the feature usable: without it, hyphenated identifiers
and ISO dates would sort absurdly. Under `-t`/`-k` the collated string **is the
field**, so `collate -t, -k2` treats a leading `-` in field 2 as a sign — no
extra plumbing needed.

Negatives get their own primary class (`0x28`, between punctuation and digits),
so every negative sorts below every non-negative while still ranking above bare
punctuation. Within negatives the order inverts — a bigger magnitude is a smaller
value — which is done by **complementing** the length and digit weights, so
`memcmp` still works unchanged.

## Dots: versions by default, decimals on request

These two readings are **mutually exclusive** and both are common:

| input | as a version | as a decimal |
|---|---|---|
| `1.9` vs `1.10` | `1.9 < 1.10` | `1.10 < 1.9` |

There is no order that satisfies both, which is precisely why coreutils ships
`-n`, `-V`, and `-g` as separate flags instead of unifying them. So:

- **Default: every `.` is a separator** — version and filename semantics
  (`1.9 < 1.10`). This is the default because dotted-number data in the wild is
  overwhelmingly version- and path-shaped.
- **`-d` / `--decimal`**: the first `.` of a *leading* number is a decimal point
  (`1.10 < 1.9`, `0.45 < 0.5`, `1 < 1.5 < 2`). `--version-sort` is the explicit
  form of the default, so a later argument can override an earlier `-d`.

`--decimal` applies **only at offset 0**, so `v1.9 < v1.10` regardless of the
flag, and a second dot in the same number is always a separator.

## What this buys you

- **Arbitrary-precision numeric ordering of runs embedded in general text**, in
  one pass, with no per-file mode selection. `sort -n` and `sort -V` are also
  arbitrary precision, but each is a whole-line numeric mode; here it is one
  facet of a general collation that is simultaneously handling case, diacritics,
  ligatures, whitespace, and punctuation.
- **`memcmp`-comparable keys.** Precompute once, compare many; usable directly as
  B-tree keys, SQLite BLOBs, or sorted-file keys with no custom comparator.
- **Reproducible everywhere** — no locale, so the same bytes in, same bytes out on
  glibc, musl, macOS, and Windows.
- **Better than `sort -g`**, which converts to `long double` and silently loses
  precision past ~19 significant digits. `9999999999999999999999999` vs
  `10000000000000000000000000` collapse to the same value, so `-g` ties and falls
  back to byte order — which is inverted. We get it right; `bc` agrees.

## Caveats — where this is wrong or surprising

Every item below is verified behavior, not speculation.

| # | behavior | why |
|---|---|---|
| 1 | **Leading zeros are invisible**: `007`, `07`, `7` produce identical keys and compare EQUAL | Only *significant* digits are weighted. The library's order is a preorder, not a total order. The CLI breaks such ties on raw line bytes, so output is still deterministic (`007 07 7`), but direct FFI users get whatever their sort does with ties. |
| 2 | **`-0` sorts before `0`** | `-0` takes the negative class; mathematically they are equal. |
| 3 | **Thousands separators are not understood**: `1,234 < 999` | `,` is punctuation, so this reads as `1`, `,`, `234`. Locale-dependent (`1,234` vs `1.234`) and therefore out of scope for a locale-free library. |
| 4 | **A sign is not recognized mid-string**: `x -5` sorts before `x -10` | The offset-0 rule. Use `-t`/`-k` to make the number a field, which *is* offset 0. |
| 5 | **An explicit `+` is not a sign**: `+5 < -3` | `+` stays punctuation, which ranks below the negative class. Mixing explicit `+` with `-` gives wrong results. |
| 6 | **Exponent notation is not understood**: `1e10 < 2e5` | `1e10` reads as `1`, `e`, `10`. No scientific-notation parsing. |
| 7 | **In default (version) mode, a dotted negative only signs the integer part**: `-1.4 < -1.5` | The fraction is a separate positive run. Numerically wrong, but self-consistent as *version* ordering. Use `-d` for real-number behavior. |
| 8 | **Under `-d`, trailing zeros in a fraction tie**: `1.5` == `1.50` | Trailing zeros are not significant; the CLI tie-breaks on raw bytes. |
| 9 | **Digits must be ASCII `0`–`9`** | Fullwidth `５` and other Unicode digit forms fall to `CLASS_OTHER` and get no numeric treatment. See the fullwidth-folding item in PLAN.md. |
| 10 | **Theoretical length bound** | The long-form length uses at most 8 base-254 bytes, i.e. up to 254⁸ significant digits. Reaching it requires more input than can physically exist, but it is a bound rather than true infinity. |

## Where the tests live

- `src/collation.zig` — unit tests: past-the-cap retention, digit-count
  monotonicity swept across the escalation and base-254 boundaries, a metamorphic
  *append-a-digit-always-increases* invariant (oracle-free), inverted negatives,
  `OPT_DECIMAL` behavior, and a guard that unsigned integers stay byte-identical
  to the pre-arbitrary-precision keys.
- `tests/integration/numeric_sort.sh` — CLI end-to-end, plus a **differential
  oracle against `bc`** (independent arbitrary-precision) over 60 generated
  integers straddling the 250-digit boundary, corroborated against `sort -n`, and
  a negative control demonstrating the `sort -g` precision failure.
