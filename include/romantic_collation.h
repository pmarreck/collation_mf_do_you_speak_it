/*
 * romantic_collation — public C FFI header.
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

#ifndef ROMANTIC_COLLATION_H
#define ROMANTIC_COLLATION_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Options bitmask (passed to rcol_open) ─────────────────────────────────
 *
 * The default (options == 0) is the OPINIONATED HOUSE STYLE:
 *   - structural-first: whitespace < punctuation < digits < letters
 *   - natural numeric runs ON (file2 < file10)
 *   - case-insensitive base letters (apple ~ Apple), case as final tie-break
 *     (lowercase before uppercase)
 *   - most diacritics as a secondary tie-break (café near cafe, not after z);
 *     Spanish ñ and Romanian ă â î ș ț occupy documented primary positions
 *   - Romanian ș/ț compare equal to legacy ş/ţ and decomposed below-mark forms
 */

/* Pure UTF-8 byte / code-point order (== `LC_ALL=C sort`). The escape hatch.
 * When set, all other option bits are ignored. */
#define RCOL_CODE_POINT     (1u << 0)

/* Reserved for future use. Natural numeric runs are ON by default in house
 * style; this bit will let a caller disable them. v1: no-op. */
#define RCOL_NUMERIC        (1u << 1)

/* Reserved for future use. Case is a final tie-break by default; this bit
 * will promote case to a primary distinction. v1: no-op. */
#define RCOL_CASE_SENSITIVE (1u << 2)

/* Read `.` in every digit run as a decimal point (1.10 < 1.9) instead of a
 * separator. OFF by default: dotted numbers in the wild are
 * overwhelmingly version- and filename-shaped, where 1.9 < 1.10 is wanted.
 * The two readings are mutually exclusive — no single order satisfies both,
 * which is why coreutils ships `-n`, `-V` and `-g` separately rather than
 * unifying them. A sign still applies only at offset 0 of the collated string,
 * so "peter-3" keeps separator semantics. Decimal mode therefore must not be
 * used for version strings: `v1.10 < v1.9` under this option. */
#define RCOL_DECIMAL        (1u << 3)

/* With RCOL_DECIMAL or RCOL_SCIENTIFIC, ',' is the decimal separator rather
 * than '.'. Digit-group absorption still requires RCOL_DECIMAL; without either
 * numeric-mode bit, this setting has no effect.
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
#define RCOL_DECIMAL_COMMA  (1u << 4)

/* Recognize scientific notation (1.5e10, 2E-5, 1e+3) and order by VALUE.
 * Every number is normalized to (exponent, mantissa) form — including ones with
 * no explicit exponent, which are simply exponent 0 — so a list mixing `1234`
 * and `2e5` orders correctly rather than being undefined.
 *
 * Independent of RCOL_DECIMAL: this bit adds exponents, DECIMAL adds
 * digit-group absorption. Setting both is what `--numeric` does. */
#define RCOL_SCIENTIFIC     (1u << 5)

/* Order whole-token Roman numerals by VALUE (VII < IX) rather than as text.
 * Opt-in because detection is irreducibly ambiguous: "MIX" is a real word AND a
 * canonical numeral for 1009. COMPLETE means bounded as a Unicode word under
 * pinned UAX #29 / Unicode 17.0.0 data, the `\bIX\b` model. Only CANONICAL
 * spellings in uniform case qualify, which rejects "CIVIL", "DID", "IIII",
 * "Mix", "MIXé", "IX2", and "IX_".
 * A recognized numeral becomes a numeric element, so IV sorts between 3 and 5
 * and therefore below every letter, per the structural-first rule. */
#define RCOL_ROMAN          (1u << 6)

/* ── Status and comparison results ─────────────────────────────────────── */

/* Fixed-width status type keeps the ABI stable across C compilers. Every
 * fallible call returns one of these; useful results use out-parameters. */
typedef int32_t rcol_status;

#define RCOL_OK                 ((rcol_status)0)
#define RCOL_INVALID_ARGUMENT   ((rcol_status)1)
#define RCOL_OUT_OF_MEMORY      ((rcol_status)2)
#define RCOL_BUFFER_TOO_SMALL   ((rcol_status)3)
#define RCOL_UNSUPPORTED_ABI    ((rcol_status)4)
#define RCOL_UNSUPPORTED_OPTION ((rcol_status)5)

#define RCOL_LESS     (-1)
#define RCOL_EQUAL      0
#define RCOL_GREATER    1

#define RCOL_ABI_VERSION 1u

/* `struct_size` permits future fields to be appended without breaking callers;
 * `abi_version` changes only when an incompatible ABI is introduced. */
typedef struct rcol_config {
    size_t struct_size;
    uint32_t abi_version;
    uint32_t options;
} rcol_config;

#define RCOL_CONFIG_INIT(options_) \
    { sizeof(rcol_config), RCOL_ABI_VERSION, (uint32_t)(options_) }

/* ── Opaque collator handle (analog of ICU's UCollator) ────────────────── */

typedef struct rcol_collator rcol_collator;

/* ── Public API ────────────────────────────────────────────────────────── */

/**
 * Return the library version as a NUL-terminated string (e.g. "0.1.0").
 * Pointer is statically allocated; do not free.
 */
const char *rcol_version(void);

/**
 * Open a collator through a size-versioned configuration. There is no locale
 * string in v1; the opinionated root order is the only order.
 *
 * `config` and `out_collator` are required. On every failure where
 * `out_collator` is non-NULL, it is set to NULL. Free a successful handle with
 * rcol_close.
 */
rcol_status rcol_open(const rcol_config *config, rcol_collator **out_collator);

/**
 * Close/free a collator returned by rcol_open. NULL-safe.
 */
void rcol_close(rcol_collator *coll);

/**
 * Compare two explicit-length UTF-8 byte strings. On RCOL_OK, `out_order` is
 * set to RCOL_LESS / RCOL_EQUAL / RCOL_GREATER. It is unchanged on failure, so
 * equality can never be confused with an allocation error.
 *
 * A string pointer may be NULL only when its corresponding length is zero.
 */
rcol_status rcol_compare_utf8(
    const rcol_collator *coll,
    const uint8_t *a, size_t alen,
    const uint8_t *b, size_t blen,
    int32_t *out_order
);

/**
 * Write a binary sort key for `s` into `out` (analog of `ucol_getSortKey`).
 * The key's `memcmp` order equals `rcol_compare_utf8` order — precompute
 * once, compare many. The key is NUL-terminated. House-style keys contain no
 * interior NUL, so C callers may compare them with `strcmp`/`memcmp`.
 * RCOL_CODE_POINT keys mirror the explicit-length input bytes and can contain
 * an interior NUL if the input does; compare those with `memcmp` and the
 * returned length.
 *
 * `out_required` is required and receives the complete key size, including the
 * trailing NUL, after successful key construction. `out == NULL, out_cap == 0`
 * is a successful length probe. An undersized nonzero buffer returns
 * RCOL_BUFFER_TOO_SMALL and remains untouched; retry with `out_required` bytes.
 * A string pointer may be NULL only when `slen` is zero.
 */
rcol_status rcol_sort_key_utf8(
    const rcol_collator *coll,
    const uint8_t *s, size_t slen,
    uint8_t *out, size_t out_cap,
    size_t *out_required
);

/**
 * Return a statically allocated English name for a status code. Unknown values
 * return "unknown status". Never returns NULL; do not free the result.
 */
const char *rcol_status_name(rcol_status status);

#ifdef __cplusplus
}
#endif

#endif /* ROMANTIC_COLLATION_H */
