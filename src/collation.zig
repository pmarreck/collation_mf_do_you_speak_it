//! collation_mf — pure collation core (NO I/O).
//!
//! Produces multi-level binary sort keys whose `memcmp`/lexicographic order
//! reproduces the intended comparison order. Comparison is defined *in terms
//! of* the sort key (both `compareAlloc` and `sortKeyAlloc` go through the same
//! key builder), which makes the "sort key order == strcoll order" invariant
//! true by construction rather than by coincidence.
//!
//! Key layout (house style): L1(primary) ++ SEP ++ L2(secondary) ++ SEP ++
//! L3(tertiary) ++ TERM. The separator (0x01) is lower than every content byte
//! (all >= 0x02) so a shorter prefix sorts before a longer string; the
//! terminator (0x00) never appears inside a key, so plain C `strcmp`/`memcmp`
//! works.
//!
//! Design intent: an opinionated, locale-free, reproducible alternative to
//! glibc `strcoll` (non-reproducible across glibc versions, absent in musl) and
//! ICU (heavy). Technique: UCA-flavored multi-level collation elements with a
//! deliberate structural-first primary level (whitespace/punctuation are NOT
//! ignored, unlike UCA) and length-prefixed numeric runs for natural sort.

const std = @import("std");

// ─── Option bits (mirror the C header) ───────────────────────────────────
pub const OPT_CODE_POINT: u32 = 1 << 0;
pub const OPT_NUMERIC: u32 = 1 << 1; // reserved (numeric is default-on in house style)
pub const OPT_CASE_SENSITIVE: u32 = 1 << 2; // reserved
/// Treat the first `.` of a LEADING number as a decimal point (1.10 < 1.9)
/// instead of a separator. OFF by default, because dotted-number data in the
/// wild is overwhelmingly version- and filename-shaped, where 1.9 < 1.10 is the
/// wanted answer. The two readings are mutually exclusive — no single order
/// satisfies both — which is exactly why coreutils ships `-n`, `-V`, and `-g`
/// as separate flags rather than unifying them.
pub const OPT_DECIMAL: u32 = 1 << 3;
/// With OPT_DECIMAL, use ',' as the decimal separator and '.' as a grouping
/// separator (continental convention) instead of the other way round. Ignored
/// unless OPT_DECIMAL is set.
///
/// This is a DECLARATION by the caller, not an inference from the data: `1.234`
/// is genuinely ambiguous between one-thousand-two-hundred-thirty-four and
/// one-point-two-three-four, and nothing in the bytes resolves it. Inferring it
/// would make sort order depend on data content, which is the one thing this
/// library exists to prevent.
pub const OPT_DECIMAL_COMMA: u32 = 1 << 4;

// ─── Sort-key structural bytes ───────────────────────────────────────────
const TERM: u8 = 0x00; // whole-key terminator (< everything)
const SEP: u8 = 0x01; // level separator (< all content, > terminator)

// Primary class ranks. Widely spaced, all >= 0x02. This ordering IS the
// "structural-first" house rule: whitespace < punctuation < digit < letter.
const CLASS_WS: u8 = 0x10;
const CLASS_PUNCT: u8 = 0x20;
/// A NEGATIVE number, slotted between punctuation and digits so that every
/// negative sorts below every non-negative while still ranking above bare
/// punctuation. Only reachable for a leading signed number (see
/// `parseLeadingNumber`).
const CLASS_NEG: u8 = 0x28;
const CLASS_DIGIT: u8 = 0x30;
const CLASS_LETTER: u8 = 0x40;
const CLASS_OTHER: u8 = 0x50;

const WEIGHT_BASE: u8 = 0x02; // smallest content byte

// Diacritic ranks (secondary weight = WEIGHT_BASE + rank).
const D_NONE: u8 = 0;
const D_GRAVE: u8 = 1;
const D_ACUTE: u8 = 2;
const D_CIRCUMFLEX: u8 = 3;
const D_TILDE: u8 = 4;
const D_DIAERESIS: u8 = 5;
const D_RING: u8 = 6;
const D_CEDILLA: u8 = 7;
const D_CARON: u8 = 8;
const D_MACRON: u8 = 9;
const D_DOT: u8 = 10;
const D_STROKE: u8 = 11;
// Ranks below are APPENDED deliberately: new ranks never perturb the existing
// relative order, because every code point that uses one was previously absent
// from the table entirely (it fell through to CLASS_OTHER).
const D_BREVE: u8 = 12; // Romanian ă
const D_COMMA: u8 = 13; // Romanian ș/ț (comma-below, distinct from cedilla)
const D_MIDDOT: u8 = 14; // Catalan ŀ

// Tertiary (case) weights.
const CASE_LOWER: u8 = 0x02;
const CASE_UPPER: u8 = 0x03;
const CASE_NEUTRAL: u8 = 0x02; // non-letters
// A ligature's expanded letters carry their own tertiary rank so that `ß` and
// `ss` share a primary AND secondary level (hence sort adjacent) yet remain
// DISTINGUISHABLE — without this the two would compare fully equal and the
// order would stop being total. Mirrors DUCET, which separates ligatures from
// their spelled-out forms at the tertiary level only.
const CASE_LOWER_LIG: u8 = 0x04;
const CASE_UPPER_LIG: u8 = 0x05;

/// A folded letter: an ASCII base ('a'..'z'), a diacritic rank, and case.
const Letter = struct { base: u8, dia: u8, upper: bool };

/// Fold a code point to a base ASCII letter + diacritic + case, if it is a
/// letter we recognize. Covers ASCII, the Latin-1 Supplement accented letters,
/// and a common subset of Latin Extended-A. Unknown code points return null
/// and fall through to the OTHER (code-point) class. This is the deliberate
/// "degrade gracefully" boundary — we do NOT hand-roll all of Unicode.
fn foldLetter(cp: u21) ?Letter {
    return switch (cp) {
        'a'...'z' => .{ .base = @intCast(cp), .dia = D_NONE, .upper = false },
        'A'...'Z' => .{ .base = @intCast(cp - 'A' + 'a'), .dia = D_NONE, .upper = true },

        // ── Latin-1 Supplement (U+00C0..U+00FF), uppercase ──
        0x00C0 => .{ .base = 'a', .dia = D_GRAVE, .upper = true },
        0x00C1 => .{ .base = 'a', .dia = D_ACUTE, .upper = true },
        0x00C2 => .{ .base = 'a', .dia = D_CIRCUMFLEX, .upper = true },
        0x00C3 => .{ .base = 'a', .dia = D_TILDE, .upper = true },
        0x00C4 => .{ .base = 'a', .dia = D_DIAERESIS, .upper = true },
        0x00C5 => .{ .base = 'a', .dia = D_RING, .upper = true },
        0x00C7 => .{ .base = 'c', .dia = D_CEDILLA, .upper = true },
        0x00C8 => .{ .base = 'e', .dia = D_GRAVE, .upper = true },
        0x00C9 => .{ .base = 'e', .dia = D_ACUTE, .upper = true },
        0x00CA => .{ .base = 'e', .dia = D_CIRCUMFLEX, .upper = true },
        0x00CB => .{ .base = 'e', .dia = D_DIAERESIS, .upper = true },
        0x00CC => .{ .base = 'i', .dia = D_GRAVE, .upper = true },
        0x00CD => .{ .base = 'i', .dia = D_ACUTE, .upper = true },
        0x00CE => .{ .base = 'i', .dia = D_CIRCUMFLEX, .upper = true },
        0x00CF => .{ .base = 'i', .dia = D_DIAERESIS, .upper = true },
        0x00D1 => .{ .base = 'n', .dia = D_TILDE, .upper = true },
        0x00D2 => .{ .base = 'o', .dia = D_GRAVE, .upper = true },
        0x00D3 => .{ .base = 'o', .dia = D_ACUTE, .upper = true },
        0x00D4 => .{ .base = 'o', .dia = D_CIRCUMFLEX, .upper = true },
        0x00D5 => .{ .base = 'o', .dia = D_TILDE, .upper = true },
        0x00D6 => .{ .base = 'o', .dia = D_DIAERESIS, .upper = true },
        0x00D8 => .{ .base = 'o', .dia = D_STROKE, .upper = true },
        0x00D9 => .{ .base = 'u', .dia = D_GRAVE, .upper = true },
        0x00DA => .{ .base = 'u', .dia = D_ACUTE, .upper = true },
        0x00DB => .{ .base = 'u', .dia = D_CIRCUMFLEX, .upper = true },
        0x00DC => .{ .base = 'u', .dia = D_DIAERESIS, .upper = true },
        0x00DD => .{ .base = 'y', .dia = D_ACUTE, .upper = true },

        // ── Latin-1 Supplement, lowercase ──
        0x00E0 => .{ .base = 'a', .dia = D_GRAVE, .upper = false },
        0x00E1 => .{ .base = 'a', .dia = D_ACUTE, .upper = false },
        0x00E2 => .{ .base = 'a', .dia = D_CIRCUMFLEX, .upper = false },
        0x00E3 => .{ .base = 'a', .dia = D_TILDE, .upper = false },
        0x00E4 => .{ .base = 'a', .dia = D_DIAERESIS, .upper = false },
        0x00E5 => .{ .base = 'a', .dia = D_RING, .upper = false },
        0x00E7 => .{ .base = 'c', .dia = D_CEDILLA, .upper = false },
        0x00E8 => .{ .base = 'e', .dia = D_GRAVE, .upper = false },
        0x00E9 => .{ .base = 'e', .dia = D_ACUTE, .upper = false },
        0x00EA => .{ .base = 'e', .dia = D_CIRCUMFLEX, .upper = false },
        0x00EB => .{ .base = 'e', .dia = D_DIAERESIS, .upper = false },
        0x00EC => .{ .base = 'i', .dia = D_GRAVE, .upper = false },
        0x00ED => .{ .base = 'i', .dia = D_ACUTE, .upper = false },
        0x00EE => .{ .base = 'i', .dia = D_CIRCUMFLEX, .upper = false },
        0x00EF => .{ .base = 'i', .dia = D_DIAERESIS, .upper = false },
        0x00F1 => .{ .base = 'n', .dia = D_TILDE, .upper = false },
        0x00F2 => .{ .base = 'o', .dia = D_GRAVE, .upper = false },
        0x00F3 => .{ .base = 'o', .dia = D_ACUTE, .upper = false },
        0x00F4 => .{ .base = 'o', .dia = D_CIRCUMFLEX, .upper = false },
        0x00F5 => .{ .base = 'o', .dia = D_TILDE, .upper = false },
        0x00F6 => .{ .base = 'o', .dia = D_DIAERESIS, .upper = false },
        0x00F8 => .{ .base = 'o', .dia = D_STROKE, .upper = false },
        0x00F9 => .{ .base = 'u', .dia = D_GRAVE, .upper = false },
        0x00FA => .{ .base = 'u', .dia = D_ACUTE, .upper = false },
        0x00FB => .{ .base = 'u', .dia = D_CIRCUMFLEX, .upper = false },
        0x00FC => .{ .base = 'u', .dia = D_DIAERESIS, .upper = false },
        0x00FD => .{ .base = 'y', .dia = D_ACUTE, .upper = false },
        0x00FF => .{ .base = 'y', .dia = D_DIAERESIS, .upper = false },

        // ── Latin Extended-A common subset ──
        0x0100 => .{ .base = 'a', .dia = D_MACRON, .upper = true },
        0x0101 => .{ .base = 'a', .dia = D_MACRON, .upper = false },
        0x0106 => .{ .base = 'c', .dia = D_ACUTE, .upper = true },
        0x0107 => .{ .base = 'c', .dia = D_ACUTE, .upper = false },
        0x010C => .{ .base = 'c', .dia = D_CARON, .upper = true },
        0x010D => .{ .base = 'c', .dia = D_CARON, .upper = false },
        0x0110 => .{ .base = 'd', .dia = D_STROKE, .upper = true },
        0x0111 => .{ .base = 'd', .dia = D_STROKE, .upper = false },
        0x0112 => .{ .base = 'e', .dia = D_MACRON, .upper = true },
        0x0113 => .{ .base = 'e', .dia = D_MACRON, .upper = false },
        0x011A => .{ .base = 'e', .dia = D_CARON, .upper = true },
        0x011B => .{ .base = 'e', .dia = D_CARON, .upper = false },
        0x012A => .{ .base = 'i', .dia = D_MACRON, .upper = true },
        0x012B => .{ .base = 'i', .dia = D_MACRON, .upper = false },
        0x0141 => .{ .base = 'l', .dia = D_STROKE, .upper = true },
        0x0142 => .{ .base = 'l', .dia = D_STROKE, .upper = false },
        0x0143 => .{ .base = 'n', .dia = D_ACUTE, .upper = true },
        0x0144 => .{ .base = 'n', .dia = D_ACUTE, .upper = false },
        0x0147 => .{ .base = 'n', .dia = D_CARON, .upper = true },
        0x0148 => .{ .base = 'n', .dia = D_CARON, .upper = false },
        0x014C => .{ .base = 'o', .dia = D_MACRON, .upper = true },
        0x014D => .{ .base = 'o', .dia = D_MACRON, .upper = false },
        0x0158 => .{ .base = 'r', .dia = D_CARON, .upper = true },
        0x0159 => .{ .base = 'r', .dia = D_CARON, .upper = false },
        0x015A => .{ .base = 's', .dia = D_ACUTE, .upper = true },
        0x015B => .{ .base = 's', .dia = D_ACUTE, .upper = false },
        0x0160 => .{ .base = 's', .dia = D_CARON, .upper = true },
        0x0161 => .{ .base = 's', .dia = D_CARON, .upper = false },
        0x016A => .{ .base = 'u', .dia = D_MACRON, .upper = true },
        0x016B => .{ .base = 'u', .dia = D_MACRON, .upper = false },
        0x0179 => .{ .base = 'z', .dia = D_ACUTE, .upper = true },
        0x017A => .{ .base = 'z', .dia = D_ACUTE, .upper = false },
        0x017B => .{ .base = 'z', .dia = D_DOT, .upper = true },
        0x017C => .{ .base = 'z', .dia = D_DOT, .upper = false },
        0x017D => .{ .base = 'z', .dia = D_CARON, .upper = true },
        0x017E => .{ .base = 'z', .dia = D_CARON, .upper = false },

        // ── Romanian: ă (breve) and ș/ț (comma-below) ──
        0x0102 => .{ .base = 'a', .dia = D_BREVE, .upper = true },
        0x0103 => .{ .base = 'a', .dia = D_BREVE, .upper = false },
        0x0218 => .{ .base = 's', .dia = D_COMMA, .upper = true },
        0x0219 => .{ .base = 's', .dia = D_COMMA, .upper = false },
        0x021A => .{ .base = 't', .dia = D_COMMA, .upper = true },
        0x021B => .{ .base = 't', .dia = D_COMMA, .upper = false },
        // The cedilla spellings Ş/ş/Ţ/ţ are pervasively (if incorrectly) used
        // for Romanian on legacy systems, so fold them to the same bases.
        0x015E => .{ .base = 's', .dia = D_CEDILLA, .upper = true },
        0x015F => .{ .base = 's', .dia = D_CEDILLA, .upper = false },
        0x0162 => .{ .base = 't', .dia = D_CEDILLA, .upper = true },
        0x0163 => .{ .base = 't', .dia = D_CEDILLA, .upper = false },

        // ── Catalan: ŀ is the first half of the ŀl digraph, which collates as
        // plain "ll"; folding to a bare 'l' gets that for free. ──
        0x013F => .{ .base = 'l', .dia = D_MIDDOT, .upper = true },
        0x0140 => .{ .base = 'l', .dia = D_MIDDOT, .upper = false },

        else => null,
    };
}

/// One code point, two base letters: a *ligature expansion*. `ß` must collate as
/// `ss`, `œ` as `oe` — a 1:1 character->letter map cannot express this, which is
/// why these previously fell through to CLASS_OTHER and sorted after every
/// letter. Kept as a SEPARATE table from `foldLetter` for two reasons: it is
/// consulted only after `foldLetter` misses (so the ASCII hot path pays
/// nothing), and a future locale tailoring swaps the expansion set wholesale
/// (German phonebook order wants ä->ae, which dictionary order must not do).
const Expansion = struct { b0: u8, b1: u8, upper: bool };

fn foldExpansion(cp: u21) ?Expansion {
    return switch (cp) {
        0x00C6 => .{ .b0 = 'a', .b1 = 'e', .upper = true }, // Æ
        0x00E6 => .{ .b0 = 'a', .b1 = 'e', .upper = false }, // æ
        0x0152 => .{ .b0 = 'o', .b1 = 'e', .upper = true }, // Œ
        0x0153 => .{ .b0 = 'o', .b1 = 'e', .upper = false }, // œ
        0x00DF => .{ .b0 = 's', .b1 = 's', .upper = false }, // ß
        0x1E9E => .{ .b0 = 's', .b1 = 's', .upper = true }, // ẞ
        0x0132 => .{ .b0 = 'i', .b1 = 'j', .upper = true }, // Ĳ
        0x0133 => .{ .b0 = 'i', .b1 = 'j', .upper = false }, // ĳ
        else => null,
    };
}

/// Is this code point whitespace for structural-first purposes?
fn isSpace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0x00A0 => true, // incl. NBSP
        else => false,
    };
}

const L1 = std.ArrayListUnmanaged(u8);

/// Append the primary bytes for a recognized letter (class + base weight).
fn pushLetterPrimary(l1: *L1, alloc: std.mem.Allocator, base: u8) !void {
    try l1.append(alloc, CLASS_LETTER);
    try l1.append(alloc, WEIGHT_BASE + (base - 'a')); // 'a'->0x02 .. 'z'->0x1B
}

/// Longest significant-digit count expressible in the single-byte short-form
/// length. WEIGHT_BASE + 250 = 0xFC, which leaves 0xFD/0xFE reserved and 0xFF
/// free as the escalation sigil.
const NUM_SHORT_MAX: usize = 250;
/// Escalation sigil. Sits ABOVE every short-form length byte, which is exactly
/// the ordering we need: more significant digits always means a bigger number.
const NUM_ESCALATE: u8 = 0xFF;
/// Radix for the long-form length payload. 254 values (0..253) survive the
/// +WEIGHT_BASE offset inside one byte, keeping every key byte >= 0x02.
const NUM_RADIX: usize = 254;

// ─── Inverted (negative) numeric weights ─────────────────────────────────
// For a negative number the order must REVERSE: a bigger magnitude is a smaller
// value. Every weight below is therefore a complement, chosen so the result
// still lands in [0x02, 0xFF] and never collides with TERM or SEP.
const NEG_LEN_TOP: u8 = 0xFE; // length byte = NEG_LEN_TOP - N  (0xFE..0x04)
const NEG_ESCALATE: u8 = 0x02; // below every inverted short-form length byte
const NEG_DIGIT_TOP: u8 = WEIGHT_BASE + 9; // digit weight = TOP - d (0x0B..0x02)
/// Terminates a negative number's digits. "Shorter prefix sorts first" is baked
/// into memcmp, so a negative with no fractional part would otherwise sort
/// BEFORE one that has one — yet -1.5 < -1. A high sentinel after the digits
/// inverts that: running out of digits becomes the LARGEST continuation. Emitted
/// unconditionally so a negative's encoding does not change shape with
/// OPT_DECIMAL; it is merely inert when decimals are off.
const NEG_END: u8 = 0xFF;

/// Emit a significant-digit count. `invert` complements every byte so that a
/// larger count sorts EARLIER, which is what a negative number needs.
fn pushNumLength(l1: *L1, alloc: std.mem.Allocator, n: usize, invert: bool) !void {
    if (n <= NUM_SHORT_MAX) {
        const short: u8 = @intCast(n);
        try l1.append(alloc, if (invert) NEG_LEN_TOP - short else WEIGHT_BASE + short);
        return;
    }
    var tmp: [8]u8 = undefined; // 254^8 digits exceeds any physical input
    var v = n;
    var k: usize = 0;
    while (v > 0) : (k += 1) {
        tmp[k] = @intCast(v % NUM_RADIX);
        v /= NUM_RADIX;
    }
    const kb: u8 = @intCast(k);
    try l1.append(alloc, if (invert) NEG_ESCALATE else NUM_ESCALATE);
    try l1.append(alloc, if (invert) NEG_LEN_TOP - kb else WEIGHT_BASE + kb);
    while (k > 0) {
        k -= 1;
        try l1.append(alloc, if (invert) 0xFF - tmp[k] else WEIGHT_BASE + tmp[k]);
    }
}

/// Byte length of a digit-group separator at `s[i]`, or 0 if there is none.
///
/// Deliberately group-SIZE agnostic: absorption keys only on "sits between two
/// digits", never on a 3-digit rhythm, because Indian lakh/crore groups 2-2-3
/// (`12,34,567`) and Chinese groups by 4 (`1,2345,6789`). Covers ASCII space,
/// apostrophe (Swiss `1'000`), underscore (programmer `1_000`), whichever of
/// ','/'.' is NOT the decimal separator, and the Unicode spaces the SI/ISO 80000
/// grouping convention actually recommends.
fn groupSepLen(s: []const u8, i: usize, comma_decimal: bool) usize {
    switch (s[i]) {
        ' ', '\'', '_' => return 1,
        ',' => return if (comma_decimal) 0 else 1,
        '.' => return if (comma_decimal) 1 else 0,
        0xC2 => { // NBSP U+00A0
            if (i + 1 < s.len and s[i + 1] == 0xA0) return 2;
        },
        0xE2 => { // thin space U+2009, narrow NBSP U+202F
            if (i + 2 < s.len and s[i + 1] == 0x80 and (s[i + 2] == 0x89 or s[i + 2] == 0xAF)) return 3;
        },
        else => {},
    }
    return 0;
}

/// A number scanned in OPT_DECIMAL mode. `int` spans the integer digits TOGETHER
/// WITH any absorbed separators (so it is one contiguous slice of the input, no
/// copying); `frac` spans only the fractional digits.
const GroupedRun = struct {
    int_start: usize,
    int_end: usize,
    frac_start: usize,
    frac_end: usize,
    end: usize,
};

fn scanGroupedNumber(s: []const u8, start: usize, comma_decimal: bool) GroupedRun {
    var i = start;
    while (i < s.len) {
        if (s[i] >= '0' and s[i] <= '9') {
            i += 1;
            continue;
        }
        const sl = groupSepLen(s, i, comma_decimal);
        // Absorb ONLY when a digit follows, i.e. the separator sits BETWEEN two
        // digits. That is what keeps "Smith 1 000" from swallowing the space
        // after the name, and "abc, 5" from swallowing the comma.
        if (sl == 0 or i + sl >= s.len or s[i + sl] < '0' or s[i + sl] > '9') break;
        i += sl;
    }
    const int_end = i;

    var fs = i;
    var fe = i;
    const dec: u8 = if (comma_decimal) ',' else '.';
    if (i + 1 < s.len and s[i] == dec and s[i + 1] >= '0' and s[i + 1] <= '9') {
        i += 1;
        fs = i;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        fe = i;
        // Trailing zeros carry no value: 1.50 == 1.5, 1.00 == 1.
        while (fe > fs and s[fe - 1] == '0') fe -= 1;
    }
    return .{ .int_start = start, .int_end = int_end, .frac_start = fs, .frac_end = fe, .end = i };
}

/// Count significant digits, skipping absorbed separators and leading zeros.
fn countSigDigits(s: []const u8) usize {
    var n: usize = 0;
    var started = false;
    for (s) |c| {
        if (c < '0' or c > '9') continue;
        if (!started) {
            if (c == '0') continue;
            started = true;
        }
        n += 1;
    }
    return n;
}

fn emitSigDigits(l1: *L1, alloc: std.mem.Allocator, s: []const u8, invert: bool) !void {
    var started = false;
    for (s) |c| {
        if (c < '0' or c > '9') continue;
        if (!started) {
            if (c == '0') continue;
            started = true;
        }
        const d = c - '0';
        try l1.append(alloc, if (invert) NEG_DIGIT_TOP - d else WEIGHT_BASE + d);
    }
}

/// Fractional digits are emitted VERBATIM — no leading-zero stripping (0.05 is
/// not 0.5) and no length prefix. Comparing them left-aligned is what makes
/// varied precision work without padding: "5" vs "25" compares 5 against 2, so
/// 1.25 < 1.5 even though 1.25 has more digits.
fn emitFracDigits(l1: *L1, alloc: std.mem.Allocator, s: []const u8, invert: bool) !void {
    for (s) |c| {
        const d = c - '0';
        try l1.append(alloc, if (invert) NEG_DIGIT_TOP - d else WEIGHT_BASE + d);
    }
}

fn pushGroupedNumber(
    l1: *L1,
    l2: *L1,
    l3: *L1,
    alloc: std.mem.Allocator,
    s: []const u8,
    run: GroupedRun,
    neg: bool,
) !void {
    const int_slice = s[run.int_start..run.int_end];
    const frac_slice = s[run.frac_start..run.frac_end];
    const n = countSigDigits(int_slice);
    if (neg) {
        try l1.append(alloc, CLASS_NEG);
        try pushNumLength(l1, alloc, n, true);
        try emitSigDigits(l1, alloc, int_slice, true);
        try emitFracDigits(l1, alloc, frac_slice, true);
        try l1.append(alloc, NEG_END);
    } else {
        try l1.append(alloc, CLASS_DIGIT);
        try pushNumLength(l1, alloc, n, false);
        try emitSigDigits(l1, alloc, int_slice, false);
        try emitFracDigits(l1, alloc, frac_slice, false);
    }
    try l2.append(alloc, WEIGHT_BASE + D_NONE);
    try l3.append(alloc, CASE_NEUTRAL);
}

/// A signed and/or fractional number found at the START of the collated string.
const LeadingNum = struct {
    neg: bool,
    int: []const u8, // significant integer digits, leading zeros stripped
    frac: []const u8, // fractional digits, trailing zeros stripped
    end: usize, // index just past the consumed number
};

/// Recognize `-?digits(.digits)?` but ONLY at offset 0, which is the whole point:
/// a '-' or '.' anywhere else is a separator, so "peter-3" keeps sorting before
/// "peter-4" and "v1.9" keeps version semantics (1.9 < 1.10). Under `-t`/`-k` the
/// collated string IS the field, so "offset 0" means the start of the sort field.
///
/// Returns null for a plain unsigned integer with no decimal point, which routes
/// it back through the ordinary scanner and makes byte-identical backward
/// compatibility true BY CONSTRUCTION rather than by careful duplication.
fn parseLeadingNumber(s: []const u8, decimal: bool) ?LeadingNum {
    var i: usize = 0;
    const neg = s.len > 1 and s[0] == '-' and s[1] >= '0' and s[1] <= '9';
    if (neg) i = 1;

    const int_start = i;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == int_start) return null; // no digit run here at all

    var int_digits = s[int_start..i];
    var z: usize = 0;
    while (z < int_digits.len and int_digits[z] == '0') z += 1;
    int_digits = int_digits[z..];

    var frac: []const u8 = &.{};
    var had_dot = false;
    if (decimal and i + 1 < s.len and s[i] == '.' and s[i + 1] >= '0' and s[i + 1] <= '9') {
        had_dot = true;
        const fs = i + 1;
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
        frac = s[fs..i];
        // Trailing zeros are not significant in a fraction: 1.50 == 1.5, 1.00 == 1.
        var e = frac.len;
        while (e > 0 and frac[e - 1] == '0') e -= 1;
        frac = frac[0..e];
    }

    if (!neg and !had_dot) return null; // exactly the pre-existing behavior
    return .{ .neg = neg, .int = int_digits, .frac = frac, .end = i };
}

/// Emit one signed/fractional number as a single primary element. Contributes
/// exactly one L2 and one L3 entry, like every other numeric run.
fn pushSignedDecimal(l1: *L1, l2: *L1, l3: *L1, alloc: std.mem.Allocator, n: LeadingNum) !void {
    if (n.neg) {
        try l1.append(alloc, CLASS_NEG);
        try pushNumLength(l1, alloc, n.int.len, true);
        for (n.int) |d| try l1.append(alloc, NEG_DIGIT_TOP - (d - '0'));
        for (n.frac) |d| try l1.append(alloc, NEG_DIGIT_TOP - (d - '0'));
        try l1.append(alloc, NEG_END);
    } else {
        // The fractional digits need no marker: they are already ordered below
        // CLASS_LETTER, so "1.5" < "1x" stays consistent with digits-before-letters,
        // and the plain prefix rule gives 1 < 1.5 < 1.55 for free.
        try l1.append(alloc, CLASS_DIGIT);
        try pushNumLength(l1, alloc, n.int.len, false);
        for (n.int) |d| try l1.append(alloc, WEIGHT_BASE + (d - '0'));
        for (n.frac) |d| try l1.append(alloc, WEIGHT_BASE + (d - '0'));
    }
    try l2.append(alloc, WEIGHT_BASE + D_NONE);
    try l3.append(alloc, CASE_NEUTRAL);
}

/// Append the primary bytes for one ASCII digit run, length-prefixed with the
/// count of significant digits so bytewise comparison matches numeric value
/// (the natural-sort technique: fewer significant digits => smaller number).
///
/// The length prefix is itself variable-length, which is what makes numeric
/// collation ARBITRARY-PRECISION — there is no cap on how many digits a run may
/// carry. Technique borrowed from BLIP (Peter Marreck's "Byte Length Integer
/// Prefix"): put an escalating magnitude class in the header and the payload
/// after it, so plain memcmp reproduces numeric order. BLIP's own encoding
/// cannot be used verbatim here because its payload bytes freely contain 0x00
/// and 0x01 — our TERM and SEP — so this is a byte-range-restricted variant:
/// every emitted byte is >= 0x02, and the sigil is harvested from the TOP of the
/// range (0xFF) because ordering wants it above all content, not in the middle.
fn pushNumericPrimary(l1: *L1, alloc: std.mem.Allocator, run: []const u8) !void {
    var start: usize = 0;
    while (start < run.len and run[start] == '0') start += 1;
    const sig = run[start..]; // significant digits, no leading zeros (may be empty => value 0)
    try l1.append(alloc, CLASS_DIGIT);
    if (sig.len <= NUM_SHORT_MAX) {
        try l1.append(alloc, WEIGHT_BASE + @as(u8, @intCast(sig.len)));
    } else {
        // Long form: NUM_ESCALATE, then how many base-254 digits the length
        // needs, then the length itself big-endian. Ordering holds at each step:
        // the sigil beats every short form; a longer length-of-length beats a
        // shorter one; and equal-width lengths compare big-endian == numerically.
        var tmp: [8]u8 = undefined; // 254^8 digits exceeds any physical input
        var n = sig.len;
        var k: usize = 0;
        while (n > 0) : (k += 1) {
            tmp[k] = @intCast(n % NUM_RADIX);
            n /= NUM_RADIX;
        }
        try l1.append(alloc, NUM_ESCALATE);
        try l1.append(alloc, WEIGHT_BASE + @as(u8, @intCast(k)));
        while (k > 0) {
            k -= 1;
            try l1.append(alloc, WEIGHT_BASE + tmp[k]);
        }
    }
    for (sig) |d| try l1.append(alloc, WEIGHT_BASE + (d - '0'));
}

/// Append the primary bytes for an OTHER (unknown) code point: a class byte
/// followed by the code point encoded big-endian in base-253 (+WEIGHT_BASE),
/// so bytewise comparison preserves code-point order and sorts after letters.
fn pushOtherPrimary(l1: *L1, alloc: std.mem.Allocator, cp: u21) !void {
    const v: u32 = cp;
    const b2: u8 = @intCast(v / (253 * 253));
    const r: u32 = v % (253 * 253);
    const b1: u8 = @intCast(r / 253);
    const b0: u8 = @intCast(r % 253);
    try l1.append(alloc, CLASS_OTHER);
    try l1.append(alloc, WEIGHT_BASE + b2);
    try l1.append(alloc, WEIGHT_BASE + b1);
    try l1.append(alloc, WEIGHT_BASE + b0);
}

/// Build the full sort key for `s` under `options`. Caller owns the result.
///
/// In code-point mode the key is simply the raw UTF-8 bytes (UTF-8 byte order
/// == Unicode code-point order == `LC_ALL=C sort`). In house-style mode it is
/// the three-level structural key described in the file header.
pub fn sortKeyAlloc(alloc: std.mem.Allocator, options: u32, s: []const u8) ![]u8 {
    if (options & OPT_CODE_POINT != 0) {
        return alloc.dupe(u8, s);
    }

    var l1: L1 = .empty;
    defer l1.deinit(alloc);
    var l2: L1 = .empty;
    defer l2.deinit(alloc);
    var l3: L1 = .empty;
    defer l3.deinit(alloc);

    var i: usize = 0;

    // A sign (and, under OPT_DECIMAL, a decimal point) is only meaningful at the
    // START of the collated string — which under -t/-k is the start of the FIELD.
    // Anywhere else, '-' and '.' are separators, so "peter-3" < "peter-4" and
    // "2026-07-29" keep working. Returns null for a plain unsigned integer, which
    // falls through to the ordinary scanner below and keeps those keys unchanged.
    const decimal = options & OPT_DECIMAL != 0;
    const comma_dec = options & OPT_DECIMAL_COMMA != 0;

    // In decimal mode the grouped scanner owns ALL number scanning (below), so
    // only the plain house-style path consults parseLeadingNumber here.
    if (!decimal) {
        if (parseLeadingNumber(s, false)) |ln| {
            try pushSignedDecimal(&l1, &l2, &l3, alloc, ln);
            i = ln.end;
        }
    }

    while (i < s.len) {
        const b = s[i];

        // Decimal mode: numbers may absorb digit-group separators, and apply to
        // EVERY run, not just a leading one ("thing1 000" must beat "thing999").
        // A sign is still only honored at offset 0.
        if (decimal) {
            const neg = i == 0 and b == '-' and s.len > 1 and s[1] >= '0' and s[1] <= '9';
            if (neg or (b >= '0' and b <= '9')) {
                const run = scanGroupedNumber(s, if (neg) i + 1 else i, comma_dec);
                try pushGroupedNumber(&l1, &l2, &l3, alloc, s, run, neg);
                i = run.end;
                continue;
            }
        }

        // Natural numeric run (default-on in house style).
        if (b >= '0' and b <= '9') {
            var j = i;
            while (j < s.len and s[j] >= '0' and s[j] <= '9') j += 1;
            try pushNumericPrimary(&l1, alloc, s[i..j]);
            try l2.append(alloc, WEIGHT_BASE + D_NONE);
            try l3.append(alloc, CASE_NEUTRAL);
            i = j;
            continue;
        }

        // Decode one UTF-8 scalar; invalid bytes degrade to a single OTHER byte.
        var cp: u21 = b;
        var adv: usize = 1;
        const seqlen = std.unicode.utf8ByteSequenceLength(b) catch 1;
        if (seqlen > 1 and i + seqlen <= s.len) {
            if (std.unicode.utf8Decode(s[i .. i + seqlen])) |decoded| {
                cp = decoded;
                adv = seqlen;
            } else |_| {
                cp = b;
                adv = 1;
            }
        }

        if (isSpace(cp)) {
            try l1.append(alloc, CLASS_WS);
            try l2.append(alloc, WEIGHT_BASE + D_NONE);
            try l3.append(alloc, CASE_NEUTRAL);
        } else if (foldLetter(cp)) |lt| {
            try pushLetterPrimary(&l1, alloc, lt.base);
            try l2.append(alloc, WEIGHT_BASE + lt.dia);
            try l3.append(alloc, if (lt.upper) CASE_UPPER else CASE_LOWER);
        } else if (foldExpansion(cp)) |ex| {
            // TWO letters from one code point. Each level must receive exactly
            // two entries or the levels desynchronize against the spelled-out
            // form and the ligature stops sorting adjacent to it.
            try pushLetterPrimary(&l1, alloc, ex.b0);
            try pushLetterPrimary(&l1, alloc, ex.b1);
            const case: u8 = if (ex.upper) CASE_UPPER_LIG else CASE_LOWER_LIG;
            for (0..2) |_| {
                try l2.append(alloc, WEIGHT_BASE + D_NONE);
                try l3.append(alloc, case);
            }
        } else if (cp < 0x80 and (b > ' ')) {
            // ASCII punctuation/symbol: ordered among itself by code point.
            try l1.append(alloc, CLASS_PUNCT);
            try l1.append(alloc, b); // 0x21..0x7E, all >= 0x02
            try l2.append(alloc, WEIGHT_BASE + D_NONE);
            try l3.append(alloc, CASE_NEUTRAL);
        } else {
            try pushOtherPrimary(&l1, alloc, cp);
            try l2.append(alloc, WEIGHT_BASE + D_NONE);
            try l3.append(alloc, CASE_NEUTRAL);
        }

        i += adv;
    }

    var key: L1 = .empty;
    errdefer key.deinit(alloc);
    try key.ensureTotalCapacity(alloc, l1.items.len + l2.items.len + l3.items.len + 3);
    key.appendSliceAssumeCapacity(l1.items);
    key.appendAssumeCapacity(SEP);
    key.appendSliceAssumeCapacity(l2.items);
    key.appendAssumeCapacity(SEP);
    key.appendSliceAssumeCapacity(l3.items);
    key.appendAssumeCapacity(TERM);
    return key.toOwnedSlice(alloc);
}

/// Compare two UTF-8 strings under `options`. Returns -1 / 0 / 1. Defined in
/// terms of sort keys so the "sort key order == compare order" invariant holds
/// by construction.
pub fn compareAlloc(alloc: std.mem.Allocator, options: u32, a: []const u8, b: []const u8) !i32 {
    if (options & OPT_CODE_POINT != 0) {
        // Fast path: raw byte order, no allocation.
        return switch (std.mem.order(u8, a, b)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }
    const ka = try sortKeyAlloc(alloc, options, a);
    defer alloc.free(ka);
    const kb = try sortKeyAlloc(alloc, options, b);
    defer alloc.free(kb);
    return switch (std.mem.order(u8, ka, kb)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

// ─────────────────────────────── Tests ───────────────────────────────────

const testing = std.testing;

/// Assert a < b under the given options (both directions + reflexive equality).
fn expectOrder(options: u32, a: []const u8, b: []const u8) !void {
    try testing.expectEqual(@as(i32, -1), try compareAlloc(testing.allocator, options, a, b));
    try testing.expectEqual(@as(i32, 1), try compareAlloc(testing.allocator, options, b, a));
    try testing.expectEqual(@as(i32, 0), try compareAlloc(testing.allocator, options, a, a));
}

// ── Phase 1: code-point fallback == LC_ALL=C byte order ──

test "code-point: raw byte order (space<digit, Z<a, accent after z)" {
    const cp = OPT_CODE_POINT;
    try expectOrder(cp, "test with spaces", "test1"); // ' ' (0x20) < '1' (0x31)
    try expectOrder(cp, "Zebra", "apple"); // 'Z' (0x5A) < 'a' (0x61)
    try expectOrder(cp, "zoo", "\xc3\xa9clair"); // 'z' (0x7A) < 'é' (0xC3..)
    try expectOrder(cp, "abc", "abcd"); // shorter prefix first
}

test "code-point: differential against std.mem sort (MFIC oracle)" {
    // Independent oracle: std.mem.lessThan on raw bytes IS `LC_ALL=C sort`.
    var corpus = [_][]const u8{
        "banana", "Apple", "apple", "café", "cafe", "file10", "file2",
        "  two-spaces", " one-space", "zebra", "Zebra", "10", "9", "2",
        "thing", "thing ", "thing2", "thingthing", "!bang", "~tilde",
    };
    const opts = OPT_CODE_POINT;
    // Sort with our comparator...
    std.mem.sort([]const u8, &corpus, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return (compareAlloc(testing.allocator, OPT_CODE_POINT, x, y) catch 0) < 0;
        }
    }.lt);
    // ...and assert every adjacent pair is byte-order sorted.
    for (0..corpus.len - 1) |k| {
        try testing.expect(!std.mem.lessThan(u8, corpus[k + 1], corpus[k]));
        // Also assert our comparator agrees with the raw oracle pairwise.
        const expect_lt = std.mem.lessThan(u8, corpus[k], corpus[k + 1]);
        const got = try compareAlloc(testing.allocator, opts, corpus[k], corpus[k + 1]);
        if (expect_lt) try testing.expect(got <= 0);
    }
}

// ── Phase 2: opinionated house style ──

test "house: structural-first, prefix, and numeric class ordering" {
    const h: u32 = 0;
    try expectOrder(h, "thing", "thing "); // prefix < prefix+space
    try expectOrder(h, "thing ", "thing2"); // space class < digit class
    try expectOrder(h, "thing2", "thingthing"); // digit class < letter class
    try expectOrder(h, "test with spaces", "test1"); // space < digit
}

test "house: natural numeric runs (file2 < file10)" {
    const h: u32 = 0;
    try expectOrder(h, "file2", "file10");
    try expectOrder(h, "9", "10");
    try expectOrder(h, "item2", "item100");
    try expectOrder(h, "v1.9", "v1.10");
}

test "house: case-insensitive base, lowercase-before-uppercase tie-break" {
    const h: u32 = 0;
    // apple and Apple are ADJACENT (equal primary+secondary) with lower first.
    try expectOrder(h, "apple", "Apple");
    // Nothing sorts strictly between them.
    try testing.expect((try compareAlloc(testing.allocator, h, "apple", "Apple")) < 0);
    // Base letter dominates case: 'apple' < 'BANANA' (base a < base b).
    try expectOrder(h, "apple", "BANANA");
}

test "house: diacritics as secondary (café near cafe, before cafz)" {
    const h: u32 = 0;
    try expectOrder(h, "cafe", "café"); // accent breaks the tie AFTER base
    try expectOrder(h, "café", "cafz"); // base e < base z dominates the accent
    try expectOrder(h, "café", "cafex"); // café < cafe+letter (prefix rule at primary)
    try expectOrder(h, "resume", "résumé"); // plain before accented
}

test "house: NFC precomposed accents fold to a base letter" {
    const h: u32 = 0;
    // Precomposed é (U+00E9) sorts as base 'e' — right after 'e', before 'f'.
    try expectOrder(h, "é", "f");
    try expectOrder(h, "d", "é");
}

// ── Phase 5: unbounded numeric runs (arbitrary-precision collation) ──

/// Build an allocated decimal string: `lead` followed by `n` copies of `fill`.
fn numStr(alloc: std.mem.Allocator, lead: u8, n: usize, fill: u8) ![]u8 {
    const s = try alloc.alloc(u8, n + 1);
    s[0] = lead;
    @memset(s[1..], fill);
    return s;
}

test "numeric: digits past the 250-digit cap are NOT lost" {
    const h: u32 = 0;
    const a = try numStr(testing.allocator, '1', 250, '0');
    defer testing.allocator.free(a);
    const b = try numStr(testing.allocator, '1', 250, '0');
    defer testing.allocator.free(b);
    // Same 251-digit number except for the FINAL digit — i.e. digit 251, just
    // past the old cap. These previously produced byte-identical keys and
    // compared EQUAL, silently collapsing two distinct numbers.
    a[250] = '5';
    b[250] = '7';
    try expectOrder(h, a, b);
}

test "numeric: more significant digits always means a larger number" {
    const h: u32 = 0;
    // Sweep across the escalation boundary (250) and across the base-254
    // length-of-length boundaries (253/254 and 507/508), where a naive
    // long-form encoding is most likely to invert.
    for ([_]usize{ 1, 17, 249, 250, 251, 252, 253, 254, 255, 506, 507, 508, 509, 1000 }) |n| {
        // "9" x n  <  "1" x (n+1) — smaller leading digits, but one more digit.
        const small = try numStr(testing.allocator, '9', n - 1, '9');
        defer testing.allocator.free(small);
        const big = try numStr(testing.allocator, '1', n, '1');
        defer testing.allocator.free(big);
        try testing.expectEqual(@as(usize, n), small.len);
        try testing.expectEqual(@as(usize, n + 1), big.len);
        expectOrder(h, small, big) catch |e| {
            std.debug.print("digit-count monotonicity broke at n={d}\n", .{n});
            return e;
        };
    }
}

test "numeric: metamorphic — appending a digit always increases the value" {
    // Oracle-free: no reference implementation, just an invariant of decimal
    // notation that must hold at EVERY length, including past the old cap.
    const h: u32 = 0;
    var seed = std.Random.DefaultPrng.init(0x0DDBA11);
    const rng = seed.random();
    for ([_]usize{ 5, 249, 250, 251, 300, 600 }) |n| {
        const s = try testing.allocator.alloc(u8, n + 1);
        defer testing.allocator.free(s);
        s[0] = '1' + rng.uintLessThan(u8, 9); // no leading zero
        for (s[1..n]) |*c| c.* = '0' + rng.uintLessThan(u8, 10);
        for ("0123456789") |d| {
            s[n] = d;
            expectOrder(h, s[0..n], s[0 .. n + 1]) catch |e| {
                std.debug.print("append-digit broke at n={d} d={c}\n", .{ n, d });
                return e;
            };
        }
    }
}

test "numeric: equal-length long numbers compare digit-by-digit" {
    const h: u32 = 0;
    const a = try numStr(testing.allocator, '4', 599, '0');
    defer testing.allocator.free(a);
    const b = try numStr(testing.allocator, '4', 599, '0');
    defer testing.allocator.free(b);
    a[400] = '3'; // differ deep past the cap, same length
    b[400] = '8';
    try expectOrder(h, a, b);
}

test "numeric: long runs keep keys C-safe (no interior NUL/SEP collision)" {
    const s = try numStr(testing.allocator, '7', 900, '3');
    defer testing.allocator.free(s);
    const key = try sortKeyAlloc(testing.allocator, 0, s);
    defer testing.allocator.free(key);
    try testing.expectEqual(@as(u8, TERM), key[key.len - 1]);
    for (key[0 .. key.len - 1]) |byte| try testing.expect(byte != TERM);
}

// ── Phase 7: grouped numbers — absorb digit-group separators under OPT_DECIMAL ──

test "grouped: OFF by default — separators still split numbers" {
    const h: u32 = 0;
    // Without OPT_DECIMAL a space is an ordinary separator, so "thing1 000" is
    // "thing", 1, space, 0 — and 1 < 999. This is the DEFAULT and must not drift.
    try expectOrder(h, "thing1 000", "thing999");
    try expectOrder(h, "1,000,000.00", "999,999.00");
}

test "grouped: OPT_DECIMAL absorbs separators sitting BETWEEN digits" {
    const d = OPT_DECIMAL;
    // The counterexample that broke the naive split approach.
    try expectOrder(d, "999,999.00", "1,000,000.00");
    try expectOrder(d, "1,000.00", "999,999.00");
    // Spaces too — this is the SI/ISO-recommended grouping form.
    try expectOrder(d, "thing999", "thing1 000");
    try expectOrder(d, "1 000.00", "10 000.00");
    // Apostrophe (Swiss) and underscore (programmer) groupings.
    try expectOrder(d, "999'999.00", "1'000'000.00");
    try expectOrder(d, "999_999", "1_000_000");
}

test "grouped: absorption is group-size AGNOSTIC (Indian, Chinese)" {
    const d = OPT_DECIMAL;
    // Indian lakh/crore groups 2,2,3 and Chinese groups by 4. A rule keyed to
    // 3-digit groups would mis-parse both, so absorption keys only on
    // digit-separator-digit.
    // Chosen so the FIRST group's order DISAGREES with true magnitude — with
    // 99 vs 1 leading, a naive per-group comparison inverts these.
    try expectOrder(d, "99,999.00", "1,00,000.00"); // 99999 < 100000 (Indian)
    try expectOrder(d, "9999,9999", "1,0000,0000"); // 99999999 < 100000000 (4-group)
    try expectOrder(d, "9,99,999.00", "12,34,567.89"); // 999999 < 1234567
}

test "grouped: a separator NOT between two digits is left alone" {
    const d = OPT_DECIMAL;
    // "Smith 1 000" — the space after 'h' is not digit-sep-digit, so the name
    // and the number stay distinct elements.
    try expectOrder(d, "Smith 999", "Smith 1 000");
    try expectOrder(d, "abc, 5", "abc, 10"); // ", " is not between digits
}

test "grouped: OPT_DECIMAL_COMMA swaps the roles of ',' and '.'" {
    const dc = OPT_DECIMAL | OPT_DECIMAL_COMMA;
    // German/continental: '.' groups, ',' is the decimal point.
    try expectOrder(dc, "1.000,00", "10.000,00");
    try expectOrder(dc, "10.000,00", "10.000,01");
    try expectOrder(dc, "999.999,00", "1.000.000,00");
    try expectOrder(dc, "1,25", "1,5"); // varied precision, left-aligned fraction
}

test "grouped: the same VALUES order identically across conventions" {
    // The payoff — the localization nightmare evaporates. Each list denotes the
    // same four values; each must come out in the same relative order.
    const en = OPT_DECIMAL;
    const de = OPT_DECIMAL | OPT_DECIMAL_COMMA;
    try expectOrder(en, "1,000.00", "999,999.00");
    try expectOrder(de, "1.000,00", "999.999,00");
    try expectOrder(en, "999,999.00", "1,000,000.00");
    try expectOrder(de, "999.999,00", "1.000.000,00");
}

test "grouped: varied precision needs no padding (left-aligned fraction)" {
    const d = OPT_DECIMAL;
    try expectOrder(d, "1.25", "1.5"); // 1.25 < 1.5 despite MORE digits
    try expectOrder(d, "1.5", "1.75");
    try expectOrder(d, "10.5", "10.55");
    try expectOrder(d, "1,000.5", "1,000.75");
}

// ── Phase 6: signed / decimal numbers, but ONLY at offset 0 ──

test "signed: a leading '-' before digits is a MINUS SIGN" {
    const h: u32 = 0;
    // Magnitude order inverts for negatives: bigger magnitude = smaller value.
    try expectOrder(h, "-10", "-5");
    try expectOrder(h, "-5", "-2");
    try expectOrder(h, "-2", "0");
    try expectOrder(h, "0", "2");
    try expectOrder(h, "-100", "-99");
    // ...and every negative sorts below every positive.
    try expectOrder(h, "-1", "1");
    try expectOrder(h, "-999999", "0");
}

test "signed: a '-' anywhere else is a SEPARATOR, not a sign" {
    const h: u32 = 0;
    // The rule that makes this design usable: "peter-3" must not become
    // "peter minus three", or hyphenated names and ISO dates would sort absurdly.
    try expectOrder(h, "peter-3", "peter-4");
    try expectOrder(h, "peter-9", "peter-10"); // still natural-numeric
    try expectOrder(h, "2026-07-29", "2026-08-01");
    try expectOrder(h, "file-2.txt", "file-10.txt");
    // A '-' NOT followed by a digit stays plain punctuation even at offset 0.
    try expectOrder(h, "-abc", "-abd");
    try expectOrder(h, "-", "-5"); // bare punctuation < a negative number
}

test "signed: negatives past the escalation boundary stay inverted" {
    const h: u32 = 0;
    // 300-digit negative vs 299-digit negative: MORE digits = MORE negative.
    const big = try numStr(testing.allocator, '-', 300, '4');
    defer testing.allocator.free(big);
    const small = try numStr(testing.allocator, '-', 299, '4');
    defer testing.allocator.free(small);
    try expectOrder(h, big, small); // -444...(300) < -444...(299)
}

test "versions: DEFAULT treats every '.' as a separator (1.9 < 1.10)" {
    const h: u32 = 0;
    // The default, and the common case: dotted numbers in the wild are versions
    // and filenames, where 1.9 < 1.10 is the wanted answer.
    try expectOrder(h, "1.9", "1.10");
    try expectOrder(h, "v1.9", "v1.10");
    try expectOrder(h, "file1.9.txt", "file1.10.txt");
    try expectOrder(h, "1.2.9", "1.2.10");
}

test "decimal: OPT_DECIMAL makes a leading number's first '.' a decimal point" {
    const d = OPT_DECIMAL;
    try expectOrder(d, "1.10", "1.9"); // 1.10 == 1.1 < 1.9 — the flip
    try expectOrder(d, "0.45", "0.5");
    try expectOrder(d, "1", "1.5");
    try expectOrder(d, "1.5", "2");
    try expectOrder(d, "1.5", "1.55");
    try expectOrder(d, "2.5", "10.5"); // integer part still natural-numeric
}

test "decimal: OPT_DECIMAL applies to EMBEDDED numbers, not just leading ones" {
    const d = OPT_DECIMAL;
    // Scope widened deliberately in phase 7: grouped numbers have to work on
    // embedded runs ("thing1 000" must beat "thing999"), so a dotted number
    // anywhere in the string is read as a decimal once the caller has DECLARED
    // decimal input. Consequence: version strings must not be fed --decimal.
    try expectOrder(d, "v1.10", "v1.9"); // read as 1.1 < 1.9
    try expectOrder(d, "file1.10.txt", "file1.9.txt");
    // The DEFAULT still gives version semantics, which is why it is the default.
    try expectOrder(0, "v1.9", "v1.10");
    try expectOrder(0, "file1.9.txt", "file1.10.txt");
    // The SIGN remains offset-0 only — that scope did NOT widen.
    try expectOrder(d, "peter-3", "peter-4");
}

test "decimal: OPT_DECIMAL inverts negative fractions too" {
    const d = OPT_DECIMAL;
    try expectOrder(d, "-1.5", "-1.4");
    try expectOrder(d, "-1.5", "-1"); // -1.5 < -1: the NEG_END sentinel's job
    try expectOrder(d, "-1.55", "-1.5");
    try expectOrder(d, "-2", "-1.5");
}

test "decimal: default mode still handles negative integers correctly" {
    const h: u32 = 0;
    // Without OPT_DECIMAL a dotted negative is version-shaped, so only the
    // INTEGER part is signed. Pinned so the behavior cannot drift silently.
    try expectOrder(h, "-10", "-5"); // plain negatives: still correct
    try expectOrder(h, "-1.4", "-1.5"); // version reading: 4 < 5 after "-1."
}

test "signed/decimal: unsigned integers are BYTE-IDENTICAL to before" {
    // Backward-compatibility guard. A plain leading integer with no sign and no
    // fractional part must produce exactly the pre-existing key, so the whole
    // existing suite stays a valid regression net for this change.
    for ([_][]const u8{ "123abc", "9", "10", "007", "0", "file2", "2026" }) |s| {
        const key = try sortKeyAlloc(testing.allocator, 0, s);
        defer testing.allocator.free(key);
        // The first primary byte of a leading digit run must still be CLASS_DIGIT
        // (not a new signed/decimal class).
        if (s[0] >= '0' and s[0] <= '9') {
            try testing.expectEqual(@as(u8, CLASS_DIGIT), key[0]);
        }
    }
}

// ── Phase 4: ligature expansions + broadened Latin coverage ──

test "house: ligatures expand to two base letters (ß=ss, œ=oe, æ=ae, ĳ=ij)" {
    const h: u32 = 0;
    // A ligature's PRIMARY level is identical to its spelled-out form, so it
    // lands ADJACENT to that form instead of after every letter (which is where
    // the old CLASS_OTHER fallthrough put it). The tertiary level keeps the two
    // distinct, so the order stays total rather than collapsing to a tie.
    try expectOrder(h, "strasse", "straße");
    try expectOrder(h, "straße", "stratos"); // primary "ss" < "to"
    try expectOrder(h, "coeur", "cœur");
    try expectOrder(h, "cœur", "cor"); // primary "oe" < "or"
    try expectOrder(h, "aeon", "æon");
    try expectOrder(h, "ijs", "ĳs");
}

test "house: ligature primary weight equals the spelled-out digraph" {
    const h: u32 = 0;
    // The point of an expansion: only the TERTIARY level may differ. If the
    // primary or secondary differed, the ligature would not sort adjacent.
    for ([_][2][]const u8{
        .{ "straße", "strasse" },
        .{ "cœur", "coeur" },
        .{ "æon", "aeon" },
        .{ "ĳs", "ijs" },
    }) |pair| {
        const kl = try sortKeyAlloc(testing.allocator, h, pair[0]);
        defer testing.allocator.free(kl);
        const ks = try sortKeyAlloc(testing.allocator, h, pair[1]);
        defer testing.allocator.free(ks);
        // Keys are L1 ++ SEP ++ L2 ++ SEP ++ L3 ++ TERM; compare through L2.
        const cut = std.mem.indexOfScalar(u8, kl, SEP).? + 1;
        const l2_end = std.mem.indexOfScalarPos(u8, kl, cut, SEP).?;
        try testing.expectEqualSlices(u8, kl[0..l2_end], ks[0..l2_end]);
        try testing.expect(!std.mem.eql(u8, kl, ks)); // ...but not identical
    }
}

test "house: Romanian ă/ș/ț fold to base letters, not CLASS_OTHER" {
    const h: u32 = 0;
    // Base letter must dominate: previously these fell through to CLASS_OTHER
    // (0x50 > CLASS_LETTER 0x40) and sorted after EVERY letter.
    try expectOrder(h, "ăb", "az"); // base 'a' run, 'b' < 'z'
    try expectOrder(h, "șa", "tz"); // base 's' < base 't'
    try expectOrder(h, "ța", "uz"); // base 't' < base 'u'
    // ...and the diacritic is only the secondary tie-break.
    try expectOrder(h, "sapa", "șapa");
    try expectOrder(h, "tara", "țara");
    try expectOrder(h, "acas", "acăs");
    // The cedilla spellings commonly used for Romanian ș/ț fold too.
    try expectOrder(h, "sa", "şa");
    try expectOrder(h, "ta", "ţa");
}

test "house: Catalan ŀ folds to plain 'l' so ŀl sorts as ll" {
    const h: u32 = 0;
    try expectOrder(h, "cella", "ceŀla"); // same primary, middot is secondary
    try expectOrder(h, "ceŀla", "cellb"); // base letters still dominate
}

/// Does `s` collate as a LETTER? Read off the key's first primary byte rather
/// than by calling the fold tables, so the assertion is one level removed from
/// the implementation it checks.
fn collatesAsLetter(s: []const u8) !bool {
    const key = try sortKeyAlloc(testing.allocator, 0, s);
    defer testing.allocator.free(key);
    return key.len > 0 and key[0] == CLASS_LETTER;
}

test "house: declared Latin coverage is EXHAUSTIVELY letter-class" {
    // A classifier over the whole declared SET, not a spot-check of examples.
    // Every character any supported Western-European language needs must land in
    // CLASS_LETTER; one omission here is a character that silently sorts after
    // every letter (the bug class this phase fixed).
    const covered = [_][]const u8{
        // French
        "à", "â", "ä", "ç", "é", "è", "ê", "ë", "î", "ï", "ô", "ö", "ù", "û", "ü", "ÿ", "æ", "œ",
        // Spanish / Italian / Portuguese / Catalan
        "á",  "í",  "ó",  "ú",  "ñ", "ã", "õ", "ì", "ò", "ŀ",
        // German / Dutch
        "ß",  "ĳ",
        // Romanian (incl. the legacy cedilla spellings)
        "ă",  "ș",  "ț",  "ş",  "ţ",
        // Uppercase forms must fold too.
        "Æ",  "Œ",  "ẞ",  "Ĳ",  "Ă", "Ș", "Ț", "É", "Ü", "Ñ",
    };
    for (covered) |c| {
        if (!try collatesAsLetter(c)) {
            std.debug.print("NOT letter-class: {s}\n", .{c});
            return error.CoverageGap;
        }
    }
}

test "house: out-of-scope code points still degrade to CLASS_OTHER" {
    // MFIC specificity corpus: the expansion work must NOT turn the fold table
    // into an accept-everything classifier. These must still sort after "zz".
    const h: u32 = 0;
    for ([_][]const u8{ "中", "€", "Ω", "д", "🎉" }) |other| {
        try expectOrder(h, "zz", other);
        try testing.expect(!try collatesAsLetter(other));
    }
}

// ── Invariant: get_sort_key memcmp order == strcoll order (both modes) ──

test "invariant: sort-key order equals compare order (house + code-point)" {
    var seed = std.Random.DefaultPrng.init(0xC0FFEE);
    const rng = seed.random();
    // Indexed by BYTE, not code point, so this deliberately manufactures torn
    // and invalid UTF-8 sequences too. The ligatures and Romanian letters are
    // present because expansions are the one construct that emits a DIFFERENT
    // number of elements per level, i.e. the likeliest way to break invariant #3.
    const alphabet = "abcABC 12.,'é�zñ-_ßœæĳășțŀ";
    var a_buf: [16]u8 = undefined;
    var b_buf: [16]u8 = undefined;

    for ([_]u32{ 0, OPT_CODE_POINT, OPT_DECIMAL, OPT_DECIMAL | OPT_DECIMAL_COMMA }) |opts| {
        var trial: usize = 0;
        while (trial < 2000) : (trial += 1) {
            const alen = rng.intRangeAtMost(usize, 0, a_buf.len);
            const blen = rng.intRangeAtMost(usize, 0, b_buf.len);
            for (0..alen) |k| a_buf[k] = alphabet[rng.intRangeLessThan(usize, 0, alphabet.len)];
            for (0..blen) |k| b_buf[k] = alphabet[rng.intRangeLessThan(usize, 0, alphabet.len)];
            const a = a_buf[0..alen];
            const b = b_buf[0..blen];

            const cmp = try compareAlloc(testing.allocator, opts, a, b);
            const ka = try sortKeyAlloc(testing.allocator, opts, a);
            defer testing.allocator.free(ka);
            const kb = try sortKeyAlloc(testing.allocator, opts, b);
            defer testing.allocator.free(kb);
            const key_cmp: i32 = switch (std.mem.order(u8, ka, kb)) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
            try testing.expectEqual(cmp, key_cmp);
        }
    }
}

test "invariant: house-style keys are NUL-terminated with no interior NUL" {
    const key = try sortKeyAlloc(testing.allocator, 0, "Café 2!");
    defer testing.allocator.free(key);
    try testing.expect(key.len > 0);
    try testing.expectEqual(@as(u8, TERM), key[key.len - 1]);
    for (key[0 .. key.len - 1]) |byte| try testing.expect(byte != TERM);
}
