/*
 * collation_mf_do_you_speak_it — public C FFI header.
 *
 * A fast, opinionated, reproducible string-collation library that IGNORES the
 * OS locale entirely and ships its own versioned ordering. The C surface is
 * modeled on ICU4C's `ucol_*` collator API so it feels familiar, but every
 * string is UTF-8 bytes + length (like ICU's `ucol_strcollUTF8`), never a
 * wide/UChar buffer.
 *
 * Architecture: pure Zig core (no I/O) -> this C ABI -> C CLI that dogfoods it.
 *
 * SPDX-License-Identifier: MIT
 */

#ifndef COLLATION_MF_DO_YOU_SPEAK_IT_H
#define COLLATION_MF_DO_YOU_SPEAK_IT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Options bitmask (passed to collation_mf_open) ─────────────────────────
 *
 * The default (options == 0) is the OPINIONATED HOUSE STYLE:
 *   - structural-first: whitespace < punctuation < digits < letters
 *   - natural numeric runs ON (file2 < file10)
 *   - case-insensitive base letters (apple ~ Apple), case as final tie-break
 *     (lowercase before uppercase)
 *   - diacritics as a secondary tie-break (café near cafe, not after z)
 */

/* Pure UTF-8 byte / code-point order (== `LC_ALL=C sort`). The escape hatch.
 * When set, all other option bits are ignored. */
#define COLLATION_MF_CODE_POINT     (1u << 0)

/* Reserved for future use. Natural numeric runs are ON by default in house
 * style; this bit will let a caller disable them. v1: no-op. */
#define COLLATION_MF_NUMERIC        (1u << 1)

/* Reserved for future use. Case is a final tie-break by default; this bit
 * will promote case to a primary distinction. v1: no-op. */
#define COLLATION_MF_CASE_SENSITIVE (1u << 2)

/* Read the first `.` of a LEADING number as a decimal point (1.10 < 1.9)
 * instead of a separator. OFF by default: dotted numbers in the wild are
 * overwhelmingly version- and filename-shaped, where 1.9 < 1.10 is wanted.
 * The two readings are mutually exclusive — no single order satisfies both,
 * which is why coreutils ships `-n`, `-V` and `-g` separately rather than
 * unifying them. Applies at offset 0 of the collated string only, so
 * "peter-3" and "v1.9" keep separator semantics either way. */
#define COLLATION_MF_DECIMAL        (1u << 3)

/* With COLLATION_MF_DECIMAL, ',' is the decimal separator and '.' groups digits
 * (continental convention) rather than the reverse. Ignored without DECIMAL.
 *
 * This is a DECLARATION by the caller, never an inference from the data: `1.234`
 * is genuinely ambiguous between 1234 and 1.234, and nothing in the bytes
 * resolves it. Inferring would make sort order depend on data content — the one
 * thing this library exists to prevent.
 *
 * Under DECIMAL, a digit-group separator (space, NBSP, thin space, apostrophe,
 * underscore, and whichever of ','/'.' is not the decimal mark) is absorbed into
 * the number whenever it sits BETWEEN two digits. Absorption is group-SIZE
 * agnostic, so Indian 2-2-3 (12,34,567) and Chinese 4-grouping (1,2345,6789)
 * both work. */
#define COLLATION_MF_DECIMAL_COMMA  (1u << 4)

/* Recognize scientific notation (1.5e10, 2E-5, 1e+3) and order by VALUE.
 * Every number is normalized to (exponent, mantissa) form — including ones with
 * no explicit exponent, which are simply exponent 0 — so a list mixing `1234`
 * and `2e5` orders correctly rather than being undefined.
 *
 * Independent of COLLATION_MF_DECIMAL: this bit adds exponents, DECIMAL adds
 * digit-group absorption. Setting both is what `--numeric` does. */
#define COLLATION_MF_SCIENTIFIC     (1u << 5)

/* Order whole-token Roman numerals by VALUE (VII < IX) rather than as text.
 * Opt-in because detection is irreducibly ambiguous: "MIX" is a real word AND a
 * canonical numeral for 1009. Only CANONICAL spellings of a COMPLETE token in
 * uniform case qualify, which rejects "CIVIL", "DID", "IIII" and "Mix".
 * A recognized numeral becomes a numeric element, so IV sorts between 3 and 5
 * and therefore below every letter, per the structural-first rule. */
#define COLLATION_MF_ROMAN          (1u << 6)

/* ── Comparison result (mirrors ICU's UCollationResult) ────────────────── */

#define COLLATION_MF_LESS     (-1)
#define COLLATION_MF_EQUAL      0
#define COLLATION_MF_GREATER    1

/* ── Opaque collator handle (analog of ICU's UCollator) ────────────────── */

typedef struct collation_mf_collator collation_mf_collator;

/* ── Public API ────────────────────────────────────────────────────────── */

/**
 * Return the library version as a NUL-terminated string (e.g. "0.1.0").
 * Pointer is statically allocated; do not free.
 */
const char *collation_mf_version(void);

/**
 * Open a collator for the given options bitmask (analog of `ucol_open`).
 * There is no locale string in v1 — the opinionated root order is the only
 * order. Returns NULL on allocation failure. Free with collation_mf_close.
 */
collation_mf_collator *collation_mf_open(uint32_t options);

/**
 * Close/free a collator returned by collation_mf_open. NULL-safe.
 */
void collation_mf_close(collation_mf_collator *coll);

/**
 * Compare two UTF-8 byte strings (analog of `ucol_strcollUTF8`).
 * Returns COLLATION_MF_LESS / _EQUAL / _GREATER (-1 / 0 / 1).
 */
int collation_mf_strcoll8(
    const collation_mf_collator *coll,
    const uint8_t *a, size_t alen,
    const uint8_t *b, size_t blen
);

/**
 * Write a binary sort key for `s` into `out` (analog of `ucol_getSortKey`).
 * The key's `memcmp` order equals `collation_mf_strcoll8` order — precompute
 * once, compare many. The key is NUL-terminated and contains no interior NUL,
 * so C callers may compare with `strcmp`/`memcmp`.
 *
 * Returns the total number of bytes the full key needs (including the trailing
 * NUL). If that exceeds `out_cap`, the key was truncated but the returned
 * length tells the caller how large a buffer to allocate for a full retry.
 * `out` may be NULL when `out_cap` is 0 (length-probe call).
 */
size_t collation_mf_get_sort_key(
    const collation_mf_collator *coll,
    const uint8_t *s, size_t slen,
    uint8_t *out, size_t out_cap
);

/* ── POSIX-shaped convenience wrappers (default house-style options) ─────── */

/**
 * Drop-in analog of C `strcoll`: compare two NUL-terminated UTF-8 strings
 * using the default house-style order. Returns -1 / 0 / 1.
 */
int collation_mf_strcoll(const char *a, const char *b);

/**
 * Drop-in analog of C `strxfrm`: transform `src` into a sort key written to
 * `dst` (up to `n` bytes, NUL-terminated if it fits) using default house-style
 * options. Returns the length the full key needs (excluding the trailing NUL),
 * matching `strxfrm` semantics. `dst` may be NULL when `n` is 0.
 */
size_t collation_mf_strxfrm(char *dst, const char *src, size_t n);

#ifdef __cplusplus
}
#endif

#endif /* COLLATION_MF_DO_YOU_SPEAK_IT_H */
