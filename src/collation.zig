//! romantic_collation — pure collation core (NO I/O).
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
const word_break = @import("word_break_data.zig");

// ─── Option bits (mirror the C header) ───────────────────────────────────
pub const OPT_CODE_POINT: u32 = 1 << 0;
pub const OPT_NUMERIC: u32 = 1 << 1; // reserved (numeric is default-on in house style)
pub const OPT_CASE_SENSITIVE: u32 = 1 << 2; // reserved
/// Treat `.` in every digit run as a decimal point (1.10 < 1.9) instead of a
/// separator. OFF by default, because dotted-number data in the
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
/// Recognize scientific notation (`1.5e10`, `2E-5`, `1e+3`) and order numbers by
/// VALUE. Every number is normalized to (exponent, mantissa) form — including
/// ones with no explicit exponent, which are simply exponent 0 — so a list that
/// mixes `1234` and `2e5` still orders correctly instead of being undefined.
///
/// Independent of OPT_DECIMAL: this bit adds exponent handling, OPT_DECIMAL adds
/// digit-group absorption. `--numeric` sets both.
pub const OPT_SCIENTIFIC: u32 = 1 << 5;
/// Order whole-token Roman numerals by VALUE (VII < IX) instead of as text.
/// Opt-in because detection is irreducibly ambiguous: `MIX` is a real word AND a
/// canonical numeral for 1009. Only canonical spellings of a COMPLETE token in
/// uniform case qualify, which rejects `CIVIL`, `DID`, `IIII` and `Mix`.
pub const OPT_ROMAN: u32 = 1 << 6;

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
/// `pushLeadingNegative`).
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
// These ranks were added for recognized Latin coverage. Some also select a
// global primary slot in letterPrimaryRank; their secondary values still keep
// unrelated accented forms in a total, deterministic order.
const D_BREVE: u8 = 12; // Romanian ă
const D_COMMA: u8 = 13; // Romanian ș/ț, including legacy cedilla spellings
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
/// Non-letter element produced by an expansion (the `/` in `½` → `1/2`).
const CASE_NEUTRAL_LIG: u8 = 0x06;

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
        0x015E => .{ .base = 's', .dia = D_COMMA, .upper = true },
        0x015F => .{ .base = 's', .dia = D_COMMA, .upper = false },
        0x0162 => .{ .base = 't', .dia = D_COMMA, .upper = true },
        0x0163 => .{ .base = 't', .dia = D_COMMA, .upper = false },

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
/// Compatibility expansion: one code point that collates as a SEQUENCE of other
/// characters. Returns replacement TEXT which the key builder re-scans, rather
/// than a fixed pair of letters — `Ⅷ` needs four letters and `½` needs digits
/// and punctuation, neither of which a letters-only pair could express.
///
/// The replacement is scanned with the ordinary rules, so digit runs inside it
/// still get natural-numeric treatment (`⅒` → `1/10` compares its 10 as ten).
/// This is the same relation Unicode's compatibility decomposition (NFKD)
/// defines; it is a fixed TABLE, not a dictionary, so it fits the project's
/// no-ICU constraint.
fn compatExpand(cp: u21) ?[]const u8 {
    return switch (cp) {
        // ── Latin ligatures ──
        0x00C6 => "AE", // Æ
        0x00E6 => "ae", // æ
        0x0152 => "OE", // Œ
        0x0153 => "oe", // œ
        0x00DF => "ss", // ß
        0x1E9E => "SS", // ẞ
        0x0132 => "IJ", // Ĳ
        0x0133 => "ij", // ĳ

        // ── Roman numeral characters, Number Forms U+2160..2182 ──
        0x2160 => "I",
        0x2161 => "II",
        0x2162 => "III",
        0x2163 => "IV",
        0x2164 => "V",
        0x2165 => "VI",
        0x2166 => "VII",
        0x2167 => "VIII",
        0x2168 => "IX",
        0x2169 => "X",
        0x216A => "XI",
        0x216B => "XII",
        0x216C => "L",
        0x216D => "C",
        0x216E => "D",
        0x216F => "M",
        0x2170 => "i",
        0x2171 => "ii",
        0x2172 => "iii",
        0x2173 => "iv",
        0x2174 => "v",
        0x2175 => "vi",
        0x2176 => "vii",
        0x2177 => "viii",
        0x2178 => "ix",
        0x2179 => "x",
        0x217A => "xi",
        0x217B => "xii",
        0x217C => "l",
        0x217D => "c",
        0x217E => "d",
        0x217F => "m",
        0x2180 => "M", // ↀ, 1000
        // ↁ (5000), ↂ (10000), ↇ (50000), ↈ (100000) have no ASCII spelling and
        // are deliberately left in CLASS_OTHER rather than given a wrong one.

        // ── Vulgar fractions ──
        0x00BC => "1/4",
        0x00BD => "1/2",
        0x00BE => "3/4",
        0x2150 => "1/7",
        0x2151 => "1/9",
        0x2152 => "1/10",
        0x2153 => "1/3",
        0x2154 => "2/3",
        0x2155 => "1/5",
        0x2156 => "2/5",
        0x2157 => "3/5",
        0x2158 => "4/5",
        0x2159 => "1/6",
        0x215A => "5/6",
        0x215B => "1/8",
        0x215C => "3/8",
        0x215D => "5/8",
        0x215E => "7/8",
        0x2189 => "0/3",

        // ── Letterlike symbols ──
        0x2122 => "TM", // ™
        0x2116 => "No", // №
        0x2105 => "c/o", // ℅

        else => null,
    };
}

const ROMAN_TOKENS = [_]struct { v: u16, t: []const u8 }{
    .{ .v = 1000, .t = "M" }, .{ .v = 900, .t = "CM" },
    .{ .v = 500, .t = "D" },  .{ .v = 400, .t = "CD" },
    .{ .v = 100, .t = "C" },  .{ .v = 90, .t = "XC" },
    .{ .v = 50, .t = "L" },   .{ .v = 40, .t = "XL" },
    .{ .v = 10, .t = "X" },   .{ .v = 9, .t = "IX" },
    .{ .v = 5, .t = "V" },    .{ .v = 4, .t = "IV" },
    .{ .v = 1, .t = "I" },
};

/// Value of a CANONICAL Roman numeral, or null.
///
/// Validation is parse-then-re-render: greedily consume the largest token at each
/// step, then render the resulting number back and require it to equal the input.
/// That is exactly the canonical grammar without writing the grammar — `IIII`
/// renders as `IV` and `IM` renders as `MI`, so both are rejected. Requiring the
/// WHOLE token to match is the real defense: `CIVIL`, `DID`, `MIL` and `LID` are
/// built only from Roman letters yet none of them parses.
///
/// It is not a complete defense, and cannot be — `MIX` is legitimately 1009. That
/// irreducible ambiguity is why this is behind an opt-in flag.
///
/// Mixed case is rejected so ordinary capitalized prose ("Mix") stays a word.
/// Max canonical value is 3999; the vinculum/apostrophus notations that express
/// more are not representable in plain text and are out of scope.
fn romanValue(s: []const u8) ?u16 {
    if (s.len == 0 or s.len > 15) return null; // MMMDCCCLXXXVIII is the longest
    var upper: [15]u8 = undefined;
    var saw_lower = false;
    var saw_upper = false;
    for (s, 0..) |c, i| {
        switch (c) {
            'I', 'V', 'X', 'L', 'C', 'D', 'M' => {
                saw_upper = true;
                upper[i] = c;
            },
            'i', 'v', 'x', 'l', 'c', 'd', 'm' => {
                saw_lower = true;
                upper[i] = c - ('a' - 'A');
            },
            else => return null,
        }
    }
    if (saw_lower and saw_upper) return null;
    const t = upper[0..s.len];

    var total: u16 = 0;
    var i: usize = 0;
    outer: while (i < t.len) {
        for (ROMAN_TOKENS) |tok| {
            if (std.mem.startsWith(u8, t[i..], tok.t)) {
                total += tok.v;
                i += tok.t.len;
                continue :outer;
            }
        }
        return null;
    }

    // Re-render and require an exact match: this is the canonicity check.
    var render: [15]u8 = undefined;
    var n: usize = 0;
    var rem = total;
    for (ROMAN_TOKENS) |tok| {
        while (rem >= tok.v) {
            if (n + tok.t.len > render.len) return null;
            @memcpy(render[n .. n + tok.t.len], tok.t);
            n += tok.t.len;
            rem -= tok.v;
        }
    }
    if (!std.mem.eql(u8, render[0..n], t)) return null;
    return total;
}

const WordProperty = word_break.Property;
const LocatedWordProperty = struct { property: WordProperty, start: usize };

fn isWordIgnored(property: WordProperty) bool {
    return property == .extend or property == .format or property == .zwj;
}

fn isAhLetter(property: WordProperty) bool {
    return property == .a_letter or property == .hebrew_letter;
}

fn isMidLetter(property: WordProperty) bool {
    return property == .mid_letter or property == .mid_num_let or property == .single_quote;
}

fn wordPropertyAt(s: []const u8, start: usize) struct { property: WordProperty, end: usize } {
    const lead = s[start];
    const len = std.unicode.utf8ByteSequenceLength(lead) catch return .{ .property = .other, .end = start + 1 };
    if (start + len > s.len) return .{ .property = .other, .end = start + 1 };
    const cp = std.unicode.utf8Decode(s[start .. start + len]) catch return .{ .property = .other, .end = start + 1 };
    return .{ .property = word_break.property(cp), .end = start + len };
}

fn previousWordProperty(s: []const u8, end: usize) LocatedWordProperty {
    var start = end - 1;
    while (start > 0 and s[start] & 0xC0 == 0x80) start -= 1;
    const decoded = wordPropertyAt(s, start);
    if (decoded.end != end) return .{ .property = .other, .start = end - 1 };
    return .{ .property = decoded.property, .start = start };
}

fn nextSignificantWordProperty(s: []const u8, start: usize) ?WordProperty {
    var i = start;
    while (i < s.len) {
        const decoded = wordPropertyAt(s, i);
        i = decoded.end;
        if (!isWordIgnored(decoded.property)) return decoded.property;
    }
    return null;
}

fn previousSignificantWordProperty(s: []const u8, end: usize) ?LocatedWordProperty {
    var i = end;
    while (i > 0) {
        const decoded = previousWordProperty(s, i);
        i = decoded.start;
        if (!isWordIgnored(decoded.property)) return decoded;
    }
    return null;
}

/// Apply the UAX #29 rules that can touch the start of an ASCII-letter run.
fn romanWordBoundaryBefore(s: []const u8, start: usize) bool {
    if (start == 0) return true;
    var left = previousWordProperty(s, start);
    if (isWordIgnored(left.property)) left = previousSignificantWordProperty(s, left.start) orelse return true;
    if (isAhLetter(left.property) or left.property == .numeric or left.property == .extend_num_let) return false;
    if (isMidLetter(left.property)) {
        const before_mid = previousSignificantWordProperty(s, left.start) orelse return true;
        if (isAhLetter(before_mid.property)) return false;
    }
    return true;
}

/// Apply the UAX #29 rules that can touch the end of an ASCII-letter run.
fn romanWordBoundaryAfter(s: []const u8, end: usize) bool {
    if (end == s.len) return true;
    const right = wordPropertyAt(s, end);
    // WB4 keeps Extend, Format, and ZWJ attached to the preceding character.
    if (isWordIgnored(right.property)) return false;
    if (isAhLetter(right.property) or right.property == .numeric or right.property == .extend_num_let) return false;
    if (isMidLetter(right.property)) {
        const after_mid = nextSignificantWordProperty(s, right.end) orelse return true;
        if (isAhLetter(after_mid)) return false;
    }
    return true;
}

/// Emit a Roman numeral as a numeric element, so `IV` lands between 3 and 5.
/// The secondary style weight keeps it distinguishable from the Arabic `4`.
fn pushRoman(l1: *L1, l2: *L1, l3: *L1, alloc: std.mem.Allocator, value: u16) !void {
    var buf: [5]u8 = undefined;
    var n: usize = 0;
    var v = value;
    if (v == 0) {
        buf[0] = '0';
        n = 1;
    } else {
        while (v > 0) : (v /= 10) {
            buf[n] = @intCast('0' + (v % 10));
            n += 1;
        }
        std.mem.reverse(u8, buf[0..n]);
    }
    try pushNumericPrimary(l1, alloc, buf[0..n]);
    try l2.append(alloc, WEIGHT_BASE + D_NONE + DIGIT_STYLE_ROMAN);
    try l3.append(alloc, NUM_ZERO_TOP);
}

/// Emit the elements for a compatibility expansion's replacement text, using the
/// ordinary rules so digit runs inside it still sort numerically. Every element
/// is marked with the ligature tertiary rank, which is what keeps `ß` adjacent
/// to `ss` while still distinguishable from it.
///
/// Replacements are plain ASCII by construction, so this does not recurse.
fn emitExpansion(l1: *L1, l2: *L1, l3: *L1, alloc: std.mem.Allocator, rep: []const u8, roman: bool) !void {
    // A Unicode numeral character (Ⅷ) expands to ASCII letters first, so this is
    // where --roman sees it. Checking the whole replacement keeps the rule
    // identical to the one applied to typed-out numerals.
    if (roman) {
        if (romanValue(rep)) |v| return pushRoman(l1, l2, l3, alloc, v);
    }
    var k: usize = 0;
    while (k < rep.len) {
        if (digitAt(rep, k) != null) {
            const run = scanDigitRun(rep, k);
            try pushNumericPrimary(l1, alloc, rep[k..run.end]);
            // NOT marked as expanded: an expansion is defined by having the same
            // primary AND secondary as its spelled-out form, so the marker has
            // to live at tertiary. The `/` carries it (CASE_NEUTRAL_LIG below),
            // which is enough, since every fraction has one.
            try l2.append(alloc, WEIGHT_BASE + D_NONE + run.style);
            try l3.append(alloc, leadingZeroWeight(rep[k..run.end]));
            k = run.end;
            continue;
        }
        const c = rep[k];
        if (foldLetter(c)) |lt| {
            try pushLetterPrimary(l1, alloc, lt.base, lt.dia);
            try l2.append(alloc, WEIGHT_BASE + lt.dia);
            try l3.append(alloc, if (lt.upper) CASE_UPPER_LIG else CASE_LOWER_LIG);
        } else {
            try l1.append(alloc, CLASS_PUNCT);
            try l1.append(alloc, c);
            try l2.append(alloc, WEIGHT_BASE + D_NONE);
            try l3.append(alloc, CASE_NEUTRAL_LIG);
        }
        k += 1;
    }
}

/// Is this code point whitespace for structural-first purposes?
fn isSpace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0x00A0, 0x2009, 0x202F => true,
        else => false,
    };
}

test "space classifier includes supported Unicode spaces and rejects lookalikes" {
    const whitespace = [_]u21{ ' ', '\t', '\n', '\r', 0x0B, 0x0C, 0x00A0, 0x2009, 0x202F };
    const non_whitespace = [_]u21{ '.', '_', 0x2014, 0x200B, 0x2060 };
    for (whitespace) |cp| try std.testing.expect(isSpace(cp));
    for (non_whitespace) |cp| try std.testing.expect(!isSpace(cp));
}

/// Return the byte length of a below-mark that Romanian legacy data uses for
/// `s`/`t`. Consuming it with the base keeps decomposed spellings one element.
fn romanianBelowMarkLen(s: []const u8, start: usize) usize {
    if (start >= s.len) return 0;
    const lead = s[start];
    const len = std.unicode.utf8ByteSequenceLength(lead) catch return 0;
    if (len == 1 or start + len > s.len) return 0;
    const cp = std.unicode.utf8Decode(s[start .. start + len]) catch return 0;
    return switch (cp) {
        0x0326, // COMBINING COMMA BELOW
        0x0327, // COMBINING CEDILLA
        => len,
        else => 0,
    };
}

const L1 = std.ArrayListUnmanaged(u8);

/// Return the global house alphabet position for a folded letter. The inserted
/// Spanish and Romanian letters occupy primary slots, while all other accents
/// keep their base letter's position and resolve at secondary level.
fn letterPrimaryRank(base: u8, dia: u8) u8 {
    var rank = base - 'a';
    if (base > 'a') rank += 2; // ă, â
    if (base > 'i') rank += 1; // î
    if (base > 'n') rank += 1; // ñ
    if (base > 's') rank += 1; // ș
    if (base > 't') rank += 1; // ț
    return switch (base) {
        'a' => switch (dia) {
            D_BREVE => rank + 1,
            D_CIRCUMFLEX => rank + 2,
            else => rank,
        },
        'i' => if (dia == D_CIRCUMFLEX) rank + 1 else rank,
        'n' => if (dia == D_TILDE) rank + 1 else rank,
        's', 't' => if (dia == D_COMMA) rank + 1 else rank,
        else => rank,
    };
}

/// Append the primary bytes for a recognized letter (class + alphabet weight).
fn pushLetterPrimary(l1: *L1, alloc: std.mem.Allocator, base: u8, dia: u8) !void {
    try l1.append(alloc, CLASS_LETTER);
    try l1.append(alloc, WEIGHT_BASE + letterPrimaryRank(base, dia));
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

/// Secondary weight marking that a digit run contained a non-ASCII digit form.
/// Same value, so primary ties; this keeps the order total without needing the
/// caller's tie-break, mirroring how ligatures are separated at tertiary.
const DIGIT_STYLE_ASCII: u8 = 0;
const DIGIT_STYLE_FOLDED: u8 = 1;
/// A number that was written as a Roman numeral, so `IV` stays distinguishable
/// from `4` while sorting at the same value.
const DIGIT_STYLE_ROMAN: u8 = 2;

/// Decimal value and byte length of the digit at `s[i]`, or null if there is no
/// digit there.
///
/// Folds non-ASCII decimal forms so they take part in natural-numeric ordering
/// instead of falling through to CLASS_OTHER and sorting after every letter:
///   * ASCII `0`-`9`
///   * Fullwidth `０`-`９`   U+FF10..FF19
///   * Mathematical Alphanumeric digits U+1D7CE..1D7FF — five styles of ten
///     (bold, double-struck, sans-serif, sans-serif bold, monospace), which are
///     contiguous, so the value is arithmetic rather than a table.
/// The ASCII test comes first and costs one byte compare, so the common path is
/// unaffected by the decoding below it.
fn digitAt(s: []const u8, i: usize) ?struct { v: u8, len: u8 } {
    const b = s[i];
    if (b >= '0' and b <= '9') return .{ .v = b - '0', .len = 1 };
    if (b < 0x80) return null;
    const seqlen = std.unicode.utf8ByteSequenceLength(b) catch return null;
    if (i + seqlen > s.len) return null;
    const cp = std.unicode.utf8Decode(s[i .. i + seqlen]) catch return null;
    if (cp >= 0xFF10 and cp <= 0xFF19)
        return .{ .v = @intCast(cp - 0xFF10), .len = seqlen };
    if (cp >= 0x1D7CE and cp <= 0x1D7FF)
        return .{ .v = @intCast((cp - 0x1D7CE) % 10), .len = seqlen };
    return null;
}

/// Extent of the digit run starting at `i`, plus whether any non-ASCII digit
/// form appeared in it.
fn scanDigitRun(s: []const u8, i: usize) struct { end: usize, style: u8 } {
    var j = i;
    var style: u8 = DIGIT_STYLE_ASCII;
    while (j < s.len) {
        const d = digitAt(s, j) orelse break;
        if (d.len > 1) style = DIGIT_STYLE_FOLDED;
        j += d.len;
    }
    return .{ .end = j, .style = style };
}

/// Leading zeros carry no VALUE, so they cannot live at the primary level — but
/// dropping them entirely made "007" and "7" produce identical keys, leaving the
/// library's order a preorder rather than a total order and quietly delegating
/// the tie to the CLI's raw-byte fallback. They are therefore a TERTIARY weight
/// in the default text sort: more leading zeros sorts first, and only once value
/// and diacritics have already tied.
///
/// In the numeric modes (OPT_DECIMAL / OPT_SCIENTIFIC) the distinction is
/// deliberately NOT made: there, 007 and 7 are the same number and must compare
/// equal.
const NUM_ZERO_MAX: usize = 250;
const NUM_ZERO_TOP: u8 = WEIGHT_BASE + NUM_ZERO_MAX; // 0xFC; count 0 => 0xFC

fn leadingZeroCount(run: []const u8) usize {
    var z: usize = 0;
    var k: usize = 0;
    while (k < run.len) {
        const d = digitAt(run, k) orelse break;
        if (d.v != 0) break;
        z += 1;
        k += d.len;
    }
    return z;
}

fn leadingZeroWeight(run: []const u8) u8 {
    return NUM_ZERO_TOP - @as(u8, @intCast(@min(leadingZeroCount(run), NUM_ZERO_MAX)));
}

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

fn scanGroupedNumber(s: []const u8, start: usize, comma_decimal: bool, absorb: bool) GroupedRun {
    var i = start;
    while (i < s.len) {
        if (digitAt(s, i)) |d| {
            i += d.len;
            continue;
        }
        const sl = if (absorb) groupSepLen(s, i, comma_decimal) else 0;
        // Absorb ONLY when a digit follows, i.e. the separator sits BETWEEN two
        // digits. That is what keeps "Smith 1 000" from swallowing the space
        // after the name, and "abc, 5" from swallowing the comma.
        if (sl == 0 or i + sl >= s.len or digitAt(s, i + sl) == null) break;
        i += sl;
    }
    const int_end = i;

    var fs = i;
    var fe = i;
    const dec: u8 = if (comma_decimal) ',' else '.';
    if (i + 1 < s.len and s[i] == dec and digitAt(s, i + 1) != null) {
        i += 1;
        fs = i;
        var last_nonzero_end = fs;
        while (i < s.len) {
            const d = digitAt(s, i) orelse break;
            if (d.v != 0) last_nonzero_end = i + d.len;
            i += d.len;
        }
        // Trailing zeros carry no value: 1.50 == 1.5, 1.00 == 1.
        fe = last_nonzero_end;
    }
    return .{ .int_start = start, .int_end = int_end, .frac_start = fs, .frac_end = fe, .end = i };
}

/// Count significant digits, skipping absorbed separators and leading zeros.
fn countSigDigits(s: []const u8) usize {
    var n: usize = 0;
    var started = false;
    var i: usize = 0;
    while (i < s.len) {
        if (digitAt(s, i)) |d| {
            i += d.len;
            if (!started) {
                if (d.v == 0) continue;
                started = true;
            }
            n += 1;
        } else i += 1; // an absorbed group separator
    }
    return n;
}

fn emitSigDigits(l1: *L1, alloc: std.mem.Allocator, s: []const u8, invert: bool) !void {
    var started = false;
    var i: usize = 0;
    while (i < s.len) {
        if (digitAt(s, i)) |d| {
            i += d.len;
            if (!started) {
                if (d.v == 0) continue;
                started = true;
            }
            try l1.append(alloc, if (invert) NEG_DIGIT_TOP - d.v else WEIGHT_BASE + d.v);
        } else i += 1; // an absorbed group separator
    }
}

/// Fractional digits are emitted VERBATIM — no leading-zero stripping (0.05 is
/// not 0.5) and no length prefix. Comparing them left-aligned is what makes
/// varied precision work without padding: "5" vs "25" compares 5 against 2, so
/// 1.25 < 1.5 even though 1.25 has more digits.
fn emitFracDigits(l1: *L1, alloc: std.mem.Allocator, s: []const u8, invert: bool) !void {
    var i: usize = 0;
    while (i < s.len) {
        const d = digitAt(s, i) orelse break;
        try l1.append(alloc, if (invert) NEG_DIGIT_TOP - d.v else WEIGHT_BASE + d.v);
        i += d.len;
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

/// Scan an explicit `e`/`E` exponent at `s[i]`, returning its value and the index
/// just past it. A bare `e` with no digits (e.g. "3employees") is NOT an
/// exponent, so the letter is left to the ordinary scanner.
fn scanExponent(s: []const u8, i: usize) ?struct { exp: i64, end: usize } {
    if (i >= s.len or (s[i] != 'e' and s[i] != 'E')) return null;
    var j = i + 1;
    var neg = false;
    if (j < s.len and (s[j] == '+' or s[j] == '-')) {
        neg = s[j] == '-';
        j += 1;
    }
    var v: i64 = 0;
    var saw_digit = false;
    while (j < s.len) {
        const d = digitAt(s, j) orelse break;
        saw_digit = true;
        // Saturate rather than overflow; an exponent this large is already
        // beyond any representable magnitude and ordering is preserved.
        if (v < 1_000_000_000) v = v * 10 + d.v;
        j += d.len;
    }
    if (!saw_digit) return null;
    return .{ .exp = if (neg) -v else v, .end = j };
}

/// Emit a signed exponent so that memcmp reproduces numeric order.
///
/// `value_neg` flips the whole comparison, because for a negative VALUE a larger
/// exponent means a larger magnitude and therefore a SMALLER number. The two
/// inversions compose: the sign byte flips when exactly one of (exponent is
/// negative, value is negative) holds, and the magnitude inverts under the same
/// condition.
fn pushExponent(l1: *L1, alloc: std.mem.Allocator, exp: i64, value_neg: bool) !void {
    const exp_neg = exp < 0;
    const flip = exp_neg != value_neg;
    try l1.append(alloc, if (flip) WEIGHT_BASE else WEIGHT_BASE + 1);
    const mag: u64 = @intCast(if (exp_neg) -exp else exp);
    // Render the magnitude in decimal, then reuse the ordinary length+digits
    // machinery so arbitrary exponent widths order correctly.
    var buf: [20]u8 = undefined;
    var n: usize = 0;
    var v = mag;
    if (v == 0) {
        buf[0] = '0';
        n = 1;
    } else {
        while (v > 0) : (v /= 10) {
            buf[n] = @intCast('0' + (v % 10));
            n += 1;
        }
        std.mem.reverse(u8, buf[0..n]);
    }
    const digits = buf[0..n];
    try pushNumLength(l1, alloc, countSigDigits(digits), flip);
    try emitSigDigits(l1, alloc, digits, flip);
}

/// Emit one number in scientific normal form: a zero flag, then the decimal
/// exponent of the leading significant digit, then the significant digits.
///
/// Normalizing plain numbers as exponent 0 is what lets `1234` and `2e5` be
/// compared correctly in the same list.
fn pushScientific(
    l1: *L1,
    l2: *L1,
    l3: *L1,
    alloc: std.mem.Allocator,
    s: []const u8,
    run: GroupedRun,
    exp: i64,
    neg: bool,
) !void {
    const int_slice = s[run.int_start..run.int_end];
    const frac_slice = s[run.frac_start..run.frac_end];
    const int_sig = countSigDigits(int_slice);

    // Leading zeros of the fraction are placeholders, not significant digits.
    var lead_zeros: usize = 0;
    var frac_sig_start: usize = 0;
    if (int_sig == 0) {
        while (frac_sig_start < frac_slice.len) {
            const d = digitAt(frac_slice, frac_sig_start) orelse break;
            if (d.v != 0) break;
            lead_zeros += 1;
            frac_sig_start += d.len;
        }
    }
    const frac_sig = frac_slice[frac_sig_start..];
    const is_zero = int_sig == 0 and frac_sig.len == 0;

    try l1.append(alloc, if (neg) CLASS_NEG else CLASS_DIGIT);
    if (is_zero) {
        // Zero has no meaningful exponent. For a POSITIVE value this flag is
        // load-bearing: 0x02 here versus 0x03 for nonzero puts zero below every
        // positive. For a NEGATIVE value the flag is irrelevant and deliberately
        // not inverted — NEG_END (0xFF) already beats any exponent-sign byte, so
        // every negative nonzero sorts below negative zero without help.
        // (Confirmed by mutation: inverting it here is an equivalent mutant.)
        try l1.append(alloc, WEIGHT_BASE);
        if (neg) try l1.append(alloc, NEG_END);
        try l2.append(alloc, WEIGHT_BASE + D_NONE);
        try l3.append(alloc, CASE_NEUTRAL);
        return;
    }
    try l1.append(alloc, if (neg) WEIGHT_BASE else WEIGHT_BASE + 1);

    // Decimal exponent of the leading significant digit.
    const e: i64 = if (int_sig > 0)
        @as(i64, @intCast(int_sig)) - 1
    else
        -@as(i64, @intCast(lead_zeros)) - 1;
    try pushExponent(l1, alloc, e + exp, neg);

    // Significant digits, most significant first.
    try emitSigDigits(l1, alloc, int_slice, neg);
    try emitFracDigits(l1, alloc, frac_sig, neg);
    if (neg) try l1.append(alloc, NEG_END);

    try l2.append(alloc, WEIGHT_BASE + D_NONE);
    try l3.append(alloc, CASE_NEUTRAL);
}

/// A signed integer found at the start of the collated string. Decimal-mode
/// numbers use the grouped scanner instead, so this path only preserves the
/// default version semantics for a leading ASCII minus sign.
const LeadingNegative = struct {
    digits: []const u8,
    end: usize,
};

fn parseLeadingNegative(s: []const u8) ?LeadingNegative {
    if (s.len < 2 or s[0] != '-') return null;
    const run = scanDigitRun(s, 1);
    if (run.end == 1) return null;
    return .{ .digits = s[1..run.end], .end = run.end };
}

/// Emit a leading negative integer with the same code-point-aware digit helpers
/// as every other numeric path, while retaining default-mode leading-zero order.
fn pushLeadingNegative(l1: *L1, l2: *L1, l3: *L1, alloc: std.mem.Allocator, n: LeadingNegative) !void {
    try l1.append(alloc, CLASS_NEG);
    try pushNumLength(l1, alloc, countSigDigits(n.digits), true);
    try emitSigDigits(l1, alloc, n.digits, true);
    try l1.append(alloc, NEG_END);
    try l2.append(alloc, WEIGHT_BASE + D_NONE);
    try l3.append(alloc, leadingZeroWeight(n.digits));
}

/// Append the primary bytes for one folded digit run, length-prefixed with the
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
    try l1.append(alloc, CLASS_DIGIT);
    try pushNumLength(l1, alloc, countSigDigits(run), false);
    try emitSigDigits(l1, alloc, run, false);
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
/// In code-point mode the key is raw UTF-8 bytes plus a terminal NUL (UTF-8 byte
/// order == Unicode code-point order == `LC_ALL=C sort`). In house-style mode it
/// is the three-level structural key described in the file header.
pub fn sortKeyAlloc(alloc: std.mem.Allocator, options: u32, s: []const u8) ![]u8 {
    if (options & OPT_CODE_POINT != 0) {
        const key = try alloc.alloc(u8, s.len + 1);
        @memcpy(key[0..s.len], s);
        key[s.len] = TERM;
        return key;
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
    const sci = options & OPT_SCIENTIFIC != 0;
    const roman = options & OPT_ROMAN != 0;
    const decimal = options & OPT_DECIMAL != 0 or sci;
    const comma_dec = options & OPT_DECIMAL_COMMA != 0;
    // Grouping absorption belongs to OPT_DECIMAL; OPT_SCIENTIFIC only adds
    // exponents, so scientific-alone must not swallow separators.
    const absorb = options & OPT_DECIMAL != 0;

    // In decimal mode the grouped scanner owns ALL number scanning (below), so
    // only the plain house-style path consults the leading-negative parser here.
    if (!decimal) {
        if (parseLeadingNegative(s)) |negative| {
            try pushLeadingNegative(&l1, &l2, &l3, alloc, negative);
            i = negative.end;
        }
    }

    while (i < s.len) {
        const b = s[i];

        // Decimal mode: numbers may absorb digit-group separators, and apply to
        // EVERY run, not just a leading one ("thing1 000" must beat "thing999").
        // A sign is still only honored at offset 0.
        if (decimal) {
            const signed = i == 0 and s.len > 1 and digitAt(s, 1) != null;
            const neg = signed and b == '-';
            // An explicit '+' is a sign only in a numeric mode. In the default
            // text sort it stays punctuation, which ranks BELOW CLASS_NEG and
            // would otherwise put "+5" under every negative.
            const pos = signed and b == '+';
            if (neg or pos or digitAt(s, i) != null) {
                const run = scanGroupedNumber(s, if (neg or pos) i + 1 else i, comma_dec, absorb);
                if (sci) {
                    const ex = scanExponent(s, run.end);
                    try pushScientific(&l1, &l2, &l3, alloc, s, run, if (ex) |e| e.exp else 0, neg);
                    i = if (ex) |e| e.end else run.end;
                } else {
                    try pushGroupedNumber(&l1, &l2, &l3, alloc, s, run, neg);
                    i = run.end;
                }
                continue;
            }
        }

        // A WHOLE token of Roman letters that parses canonically becomes a
        // number. Scanning the maximal ASCII-letter run is what enforces
        // "whole token": "MIXER" is one run, is not all Roman letters, and so
        // is never considered.
        if (roman and ((b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z'))) {
            var j = i;
            while (j < s.len and ((s[j] >= 'A' and s[j] <= 'Z') or (s[j] >= 'a' and s[j] <= 'z'))) j += 1;
            // A Roman numeral must occupy a complete Unicode word segment.
            // This is the `\bIX\b` intuition with pinned UAX #29 data: symbols
            // and most punctuation delimit it, while letters, digits,
            // connectors, combining marks, and contextual mid-word punctuation
            // keep it inside the surrounding word.
            const whole = romanWordBoundaryBefore(s, i) and romanWordBoundaryAfter(s, j);
            if (whole and romanValue(s[i..j]) != null) {
                try pushRoman(&l1, &l2, &l3, alloc, romanValue(s[i..j]).?);
            } else {
                // NOT a numeral: emit the ENTIRE run as letters here. Emitting a
                // single character and looping would let the check re-enter
                // mid-word and match a trailing suffix — "CIVIL" would end with
                // the number 50 and "CIVIC" with 100, inverting the two.
                for (s[i..j]) |c| {
                    const lt = foldLetter(c).?; // ASCII letters always fold
                    try pushLetterPrimary(&l1, alloc, lt.base, lt.dia);
                    try l2.append(alloc, WEIGHT_BASE + lt.dia);
                    try l3.append(alloc, if (lt.upper) CASE_UPPER else CASE_LOWER);
                }
            }
            i = j;
            continue;
        }

        // Natural numeric run (default-on in house style). Digits may be
        // fullwidth or Mathematical Alphanumeric forms, so the run is scanned by
        // code point rather than by byte.
        if (digitAt(s, i) != null) {
            const run = scanDigitRun(s, i);
            try pushNumericPrimary(&l1, alloc, s[i..run.end]);
            // Secondary: digit style, so "1" and "１" stay distinguishable.
            try l2.append(alloc, WEIGHT_BASE + D_NONE + run.style);
            // Tertiary: leading-zero count, so 007 < 07 < 7 instead of tying.
            try l3.append(alloc, leadingZeroWeight(s[i..run.end]));
            i = run.end;
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
        } else if (foldLetter(cp)) |raw_lt| {
            var lt = raw_lt;
            var consumed = adv;
            if ((lt.base == 's' or lt.base == 't') and lt.dia == D_NONE) {
                const mark_len = romanianBelowMarkLen(s, i + adv);
                if (mark_len != 0) {
                    lt.dia = D_COMMA;
                    consumed += mark_len;
                }
            }
            try pushLetterPrimary(&l1, alloc, lt.base, lt.dia);
            try l2.append(alloc, WEIGHT_BASE + lt.dia);
            try l3.append(alloc, if (lt.upper) CASE_UPPER else CASE_LOWER);
            i += consumed;
            continue;
        } else if (compatExpand(cp)) |rep| {
            // N elements from one code point. Every level must receive the same
            // count the spelled-out form produces, or the two stop sorting
            // adjacent — which is the entire point of an expansion.
            try emitExpansion(&l1, &l2, &l3, alloc, rep, roman);
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
    // Build both keys in a stack scratch buffer first. Ordinary lines fit, so
    // the common case never reaches the heap at all — which matters because
    // `strcoll8` is the POSIX-shaped entry point callers reach for directly,
    // outside the precompute-a-key-once model.
    //
    // Deliberately a scratch ALLOCATOR rather than a hand-written streaming
    // comparator: both paths still go through the one key builder, so RULES.md
    // #3 (sort-key order == compare order) stays true BY CONSTRUCTION. A
    // separate streaming comparator would demote that to true-by-testing.
    var scratch: [COMPARE_SCRATCH]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const stack = fba.allocator();
    if (sortKeyAlloc(stack, options, a)) |ka| {
        if (sortKeyAlloc(stack, options, b)) |kb| {
            return orderKeys(ka, kb); // nothing to free: scratch is the stack
        } else |_| {}
    } else |_| {}

    // At least one key outgrew the scratch (a very long line, or a huge digit
    // run). Redo both on the heap.
    const ka = try sortKeyAlloc(alloc, options, a);
    defer alloc.free(ka);
    const kb = try sortKeyAlloc(alloc, options, b);
    defer alloc.free(kb);
    return orderKeys(ka, kb);
}

/// Scratch large enough for both keys of an ordinary line. A key runs roughly
/// 4x the input (three levels plus class bytes), and the intermediate level
/// buffers grow geometrically, so this comfortably covers lines of a few hundred
/// bytes while staying small enough to sit on a thread stack.
const COMPARE_SCRATCH: usize = 8192;

fn orderKeys(ka: []const u8, kb: []const u8) i32 {
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

test "house: Spanish and Romanian letters have their global alphabet positions" {
    const h: u32 = 0;
    // Spanish ñ is a primary letter after n, rather than an n accent.
    try expectOrder(h, "nob", "ñaa");
    try expectOrder(h, "ño", "o");

    // Romanian's five primary-letter insertions. Accent-only variants of the
    // surrounding ASCII letters remain at their base positions.
    try expectOrder(h, "az", "ăa");
    try expectOrder(h, "ăz", "âa");
    try expectOrder(h, "âz", "ba");
    try expectOrder(h, "iz", "îa");
    try expectOrder(h, "îz", "ja");
    try expectOrder(h, "sz", "șa");
    try expectOrder(h, "șz", "ta");
    try expectOrder(h, "tz", "ța");
    try expectOrder(h, "țz", "ua");
}

test "house: Romanian comma-below, cedilla, and decomposed forms canonicalize" {
    const h: u32 = 0;
    for ([_][4][]const u8{
        .{ "ș", "ş", "s\u{0326}", "s\u{0327}" },
        .{ "ț", "ţ", "t\u{0326}", "t\u{0327}" },
        .{ "Ș", "Ş", "S\u{0326}", "S\u{0327}" },
        .{ "Ț", "Ţ", "T\u{0326}", "T\u{0327}" },
    }) |spellings| {
        for (spellings[1..]) |other| {
            try testing.expectEqual(@as(i32, 0), try compareAlloc(testing.allocator, h, spellings[0], other));
        }
    }
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

// ── Phase 13: compare without touching the heap for ordinary inputs ──

test "compare: ordinary inputs never reach the allocator" {
    // Proof rather than assertion: a FailingAllocator that permits ZERO
    // allocations. If compareAlloc reaches the heap at all, this fails.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const never = failing.allocator();
    for ([_][2][]const u8{
        .{ "apple", "banana" },
        .{ "file2", "file10" },
        .{ "Straße", "Strasse" },
        .{ "café", "cafz" },
        .{ "  leading space", "x" },
        .{ "2026-08-02", "2026-08-01" },
        .{ "a rather longer line of ordinary prose text", "a rather longer line of ordinary prose txt" },
    }) |pair| {
        _ = try compareAlloc(never, 0, pair[0], pair[1]);
        _ = try compareAlloc(never, OPT_CODE_POINT, pair[0], pair[1]);
        _ = try compareAlloc(never, OPT_DECIMAL, pair[0], pair[1]);
    }
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "compare: oversized inputs still work, via the heap fallback" {
    // A digit run far past the stack scratch must fall back rather than fail.
    const big_a = try numStr(testing.allocator, '1', 20_000, '7');
    defer testing.allocator.free(big_a);
    const big_b = try numStr(testing.allocator, '1', 20_000, '8');
    defer testing.allocator.free(big_b);
    try testing.expectEqual(@as(i32, -1), try compareAlloc(testing.allocator, 0, big_a, big_b));
    try testing.expectEqual(@as(i32, 1), try compareAlloc(testing.allocator, 0, big_b, big_a));
    try testing.expectEqual(@as(i32, 0), try compareAlloc(testing.allocator, 0, big_a, big_a));
}

test "compare: the fast path agrees with the key builder on random input" {
    // Differential: the stack path and the heap path must never disagree. The
    // stack path is exercised by short inputs, the heap path by long ones, so
    // sweep both sides of the boundary.
    var seed = std.Random.DefaultPrng.init(0xC0DEC0DE);
    const rng = seed.random();
    const alphabet = "abzABZ 09.,'-_é ñß½Ⅷ";
    var buf_a: [512]u8 = undefined;
    var buf_b: [512]u8 = undefined;
    for ([_]u32{ 0, OPT_DECIMAL, OPT_SCIENTIFIC, OPT_ROMAN }) |opts| {
        var trial: usize = 0;
        while (trial < 400) : (trial += 1) {
            const alen = rng.intRangeAtMost(usize, 0, buf_a.len);
            const blen = rng.intRangeAtMost(usize, 0, buf_b.len);
            for (0..alen) |k| buf_a[k] = alphabet[rng.intRangeLessThan(usize, 0, alphabet.len)];
            for (0..blen) |k| buf_b[k] = alphabet[rng.intRangeLessThan(usize, 0, alphabet.len)];
            const a = buf_a[0..alen];
            const b = buf_b[0..blen];
            // Independent recomputation straight from the key builder.
            const ka = try sortKeyAlloc(testing.allocator, opts, a);
            defer testing.allocator.free(ka);
            const kb = try sortKeyAlloc(testing.allocator, opts, b);
            defer testing.allocator.free(kb);
            const want: i32 = switch (std.mem.order(u8, ka, kb)) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            };
            try testing.expectEqual(want, try compareAlloc(testing.allocator, opts, a, b));
        }
    }
}

// ── Phase 12: --roman, ordering Roman numerals by VALUE ──

test "roman: OFF by default — I V X L C D M are ordinary letters" {
    const h: u32 = 0;
    try expectOrder(h, "IX", "VII"); // text order: I < V
    try expectOrder(h, "IV", "V");
}

test "roman: OPT_ROMAN orders whole-token numerals by value" {
    const r = OPT_ROMAN;
    try expectOrder(r, "VII", "IX"); // 7 < 9 — the flip
    try expectOrder(r, "IV", "V"); // 4 < 5
    try expectOrder(r, "IX", "X"); // 9 < 10
    try expectOrder(r, "XL", "L"); // 40 < 50
    try expectOrder(r, "XC", "C"); // 90 < 100
    try expectOrder(r, "CD", "D"); // 400 < 500
    try expectOrder(r, "CM", "M"); // 900 < 1000
    try expectOrder(r, "MCMXCIV", "MMXXVI"); // 1994 < 2026
    try expectOrder(r, "i", "iv"); // lowercase forms too
    try expectOrder(r, "vii", "ix");
}

test "roman: embedded numerals sort by value" {
    const r = OPT_ROMAN;
    try expectOrder(r, "Chapter VII", "Chapter IX");
    try expectOrder(r, "Part IV", "Part V");
}

test "roman: Unicode word boundaries delimit numeral tokens" {
    const r = OPT_ROMAN;

    // Punctuation and symbols provide boundaries on both sides.
    try expectOrder(r, "VII—", "IX—");
    try expectOrder(r, "VII™", "IX™");
    try expectOrder(r, "—VII", "—IX");

    // Letters, digits, connector punctuation, and combining marks continue the
    // word. Text order is IX < VII, the opposite of numeral value order.
    try expectOrder(r, "MIXé", "MIXf");
    try expectOrder(r, "éIX", "éVII");
    try expectOrder(r, "IX2", "VII2");
    try expectOrder(r, "IX_", "VII_");
    try expectOrder(r, "IX\u{0301}", "VII\u{0301}");

    // UAX #29 keeps letters joined across certain mid-word punctuation when a
    // letter follows it, as in example.com.
    try expectOrder(r, "IX.example", "VII.example");
    try expectOrder(r, "IX.\u{0301}example", "VII.\u{0301}example");
    try expectOrder(r, "example.\u{0301}IX", "example.\u{0301}VII");
}

test "roman: ONLY canonical whole tokens count" {
    const r = OPT_ROMAN;
    // Words built entirely from Roman letters must stay words. Each of these
    // fails the canonical grammar, which is the whole defense.
    for ([_][2][]const u8{
        .{ "CIVIC", "CIVIL" }, // parse to 205 / 155, re-render as CCV / CLV — rejected
        .{ "DID", "DIM" },
        .{ "MIL", "MILL" },
        .{ "LID", "LIDS" },
    }) |pair| {
        try expectOrder(r, pair[0], pair[1]); // plain text order preserved
    }
    // Non-canonical spellings are rejected: IIII stays a WORD, while IV is
    // accepted as the number 4 — and numbers rank below letters under
    // structural-first, so the recognized one sorts first.
    try expectOrder(r, "IV", "IIII");
    try testing.expect((try compareAlloc(testing.allocator, r, "IIII", "IIIJ")) < 0); // plain text
    // Mixed case is rejected, so capitalized prose words are safe.
    try expectOrder(r, "Mix", "Mob");
}

test "roman: 'MIX' really is 1009 — the documented ambiguity" {
    const r = OPT_ROMAN;
    // All-uppercase MIX parses canonically, so under --roman it IS a number.
    // This is why the flag is opt-in rather than automatic.
    try expectOrder(r, "M", "MIX"); // 1000 < 1009
    try expectOrder(r, "MIX", "MX"); // 1009 < 1010
}

test "roman: Unicode numeral characters go through the expansion first" {
    const r = OPT_ROMAN;
    try expectOrder(r, "Ⅶ", "Ⅸ"); // Ⅶ=7 < Ⅸ=9, opposite of text order
    try expectOrder(r, "Ⅳ", "Ⅴ");
    try expectOrder(r, "ⅶ", "ⅸ");
}

/// Under OPT_ROMAN, did `s` collate as a NUMBER rather than as a word? Read off
/// the key's first primary byte, so the check is one level removed from the
/// parser it is testing.
fn romanCollatesAsNumber(s: []const u8) !bool {
    const key = try sortKeyAlloc(testing.allocator, OPT_ROMAN, s);
    defer testing.allocator.free(key);
    return key.len > 0 and key[0] == CLASS_DIGIT;
}

test "roman: the reduced-form rule rejects real words (measured over a dictionary)" {
    // Measured against an 89,217-entry dictionary: 149 entries are built only
    // from IVXLCDM, and requiring CANONICAL (fully reduced) form rejects 52 of
    // them — nearly every multi-letter English word in the set. These are a
    // sample of that 52, pinned so the rule cannot regress silently.
    const stay_words = [_][]const u8{
        "civil", "civic", "did", "dim",  "mild", "mill", "mimic", "livid",
        "vivid", "villi", "vim", "dill", "lid",  "ill",  "mid",   "midi",
        "mic",   "mil",   "Cid", "DVD",  "LCD",  "XML",  "XXL",   "LLD",
        "LCM",   "LDC",   "ICC", "DMD",
    };
    for (stay_words) |w| {
        if (try romanCollatesAsNumber(w)) {
            std.debug.print("wrongly read as a numeral: {s}\n", .{w});
            return error.RomanFalsePositive;
        }
    }

    // These are rejected by the UNIFORM-CASE rule specifically: each parses
    // canonically once uppercased (Di=501, Md=1500, Cl=150, Cm=900, Li=51,
    // Ci=101, Cd=400, Dix=509), so they are the only cases that can tell the
    // case rule apart from the canonical rule. Without them, dropping the case
    // check entirely leaves every test green — mutation testing found exactly
    // that gap.
    const mixed_case = [_][]const u8{ "Di", "Md", "Cl", "Cm", "Li", "Ci", "Cd", "Dix" };
    for (mixed_case) |w| {
        if (try romanCollatesAsNumber(w)) {
            std.debug.print("mixed case wrongly read as a numeral: {s}\n", .{w});
            return error.RomanMixedCaseAccepted;
        }
        // ...and the all-caps spelling of the same token IS a numeral, which is
        // what makes the pair discriminating rather than vacuous.
        var upper: [8]u8 = undefined;
        for (w, 0..) |c, k| upper[k] = if (c >= 'a' and c <= 'z') c - 32 else c;
        if (!try romanCollatesAsNumber(upper[0..w.len])) {
            std.debug.print("expected all-caps {s} to be a numeral\n", .{upper[0..w.len]});
            return error.RomanUpperRejected;
        }
    }
}

test "roman: the irreducible collisions, enumerated" {
    // What survives the canonical rule: five multi-letter real words that ARE
    // canonical numerals, plus the bare letters. `div` is the non-obvious one —
    // D(500) + IV(4) = 504, which re-renders as exactly "DIV".
    // Specificity corpus for the test above: without this half, a checker that
    // rejected everything would score 100% there.
    const are_numbers = [_][]const u8{
        "mix", "CV",  "DI", "div", "MD",
        "i",   "I",   "v",  "V",   "x",
        "X",   "l",   "L",  "c",   "C",
        "d",   "D",   "m",  "M",
    };
    for (are_numbers) |w| {
        if (!try romanCollatesAsNumber(w)) {
            std.debug.print("expected a numeral, got a word: {s}\n", .{w});
            return error.RomanFalseNegative;
        }
    }
}

test "roman: numerals sort among ARABIC numbers, distinguishably" {
    const r = OPT_ROMAN;
    try expectOrder(r, "3", "IV"); // 3 < 4
    try expectOrder(r, "IV", "5"); // 4 < 5
    // Same value, so a secondary style weight keeps the order total.
    try testing.expect((try compareAlloc(testing.allocator, r, "4", "IV")) != 0);
}

// ── Phase 11: general compatibility expansion (n characters, not just 2) ──

/// Assert `single` collates exactly like `spelled` at primary+secondary, and
/// differs only at tertiary — the defining property of an expansion.
fn expectExpands(single: []const u8, spelled: []const u8) !void {
    const ka = try sortKeyAlloc(testing.allocator, 0, single);
    defer testing.allocator.free(ka);
    const kb = try sortKeyAlloc(testing.allocator, 0, spelled);
    defer testing.allocator.free(kb);
    const cut = std.mem.indexOfScalar(u8, ka, SEP).? + 1;
    const l2_end = std.mem.indexOfScalarPos(u8, ka, cut, SEP).?;
    try testing.expectEqualSlices(u8, ka[0..l2_end], kb[0..l2_end]);
    try testing.expect(!std.mem.eql(u8, ka, kb));
}

test "expand: Roman numeral characters expand past two letters" {
    const h: u32 = 0;
    try expectExpands("Ⅷ", "VIII"); // FOUR letters — the old 2-slot cap
    try expectExpands("Ⅻ", "XII");
    try expectExpands("Ⅳ", "IV");
    try expectExpands("ⅷ", "viii"); // lowercase forms too
    try expectExpands("Ⅿ", "M");
    // ...and they order among themselves as their spelled-out text.
    try expectOrder(h, "Ⅶ", "Ⅷ"); // VII < VIII (prefix)
    try expectOrder(h, "Ⅳ", "Ⅸ"); // IV < IX
}

test "expand: vulgar fractions become digit/slash/digit" {
    try expectExpands("½", "1/2");
    try expectExpands("¾", "3/4");
    try expectExpands("⅒", "1/10"); // a two-digit denominator
    try expectExpands("⅝", "5/8");
}

test "expand: letterlike symbols" {
    try expectExpands("™", "TM");
    try expectExpands("№", "No");
}

test "expand: the existing two-letter ligatures are unchanged" {
    const h: u32 = 0;
    // Phase 4 behavior must survive the mechanism swap.
    try expectExpands("ß", "ss");
    try expectExpands("œ", "oe");
    try expectExpands("æ", "ae");
    try expectExpands("ĳ", "ij");
    try expectOrder(h, "strasse", "straße");
    try expectOrder(h, "straße", "stratos");
}

test "expand: out-of-scope code points still degrade to CLASS_OTHER" {
    const h: u32 = 0;
    for ([_][]const u8{ "中", "€", "Ω", "🎉" }) |c| try expectOrder(h, "zz", c);
}

// ── Phase 10: fold non-ASCII decimal digits into the numeric run ──

test "digits: fullwidth numerals participate in natural-numeric ordering" {
    const h: u32 = 0;
    // U+FF10..FF19. Previously CLASS_OTHER, so they sorted after every letter
    // and got no numeric treatment at all.
    try expectOrder(h, "word５", "word10");
    try expectOrder(h, "９", "１０");
    try expectOrder(h, "file２", "file10");
    try expectOrder(h, "１", "２");
}

test "digits: a run may MIX widths" {
    const h: u32 = 0;
    try expectOrder(h, "9", "１0"); // fullwidth 1 + ASCII 0 == 10
    try expectOrder(h, "１0", "11"); // 10 < 11
    try expectOrder(h, "1２3", "124"); // 123 < 124, mixed run
}

test "digits: mathematical alphanumeric digits fold too" {
    const h: u32 = 0;
    // U+1D7CE..1D7FF — five styles of ten, all algorithmic.
    try expectOrder(h, "𝟐", "10"); // bold 2
    try expectOrder(h, "𝟚", "10"); // double-struck 2
    try expectOrder(h, "𝟸", "10"); // monospace 2
    try expectOrder(h, "𝟗", "𝟏𝟎"); // bold 9 < bold 10
    try expectOrder(h, "𝟣", "𝟤"); // sans-serif 1 < 2
}

test "digits: folded digits also work under the numeric modes" {
    for ([_]u32{ OPT_DECIMAL, OPT_SCIENTIFIC }) |o| {
        try expectOrder(o, "９", "１０");
        try expectOrder(o, "𝟐", "10");
    }
}

test "digits: folded forms stay DISTINGUISHABLE from ASCII (total order)" {
    const h: u32 = 0;
    // Same value, so primary and secondary tie; a tertiary style weight keeps
    // the order total rather than delegating to the caller's tie-break.
    try expectOrder(h, "1", "１");
    try testing.expect((try compareAlloc(testing.allocator, h, "1", "１")) != 0);
    try testing.expect((try compareAlloc(testing.allocator, h, "12", "1２")) != 0);
}

test "digits: folded forms work in leading signed numbers" {
    const h: u32 = 0;
    try expectOrder(h, "-10", "-５");
    try expectOrder(h, "-10", "-𝟓");
    try expectOrder(h, "-５", "-2");
}

test "digits: folded fractional zeroes preserve numeric value" {
    const decimal = OPT_DECIMAL;
    const scientific = OPT_SCIENTIFIC;
    try testing.expectEqual(
        @as(i32, 0),
        try compareAlloc(testing.allocator, decimal, "1.5", "1.５０"),
    );
    try testing.expectEqual(
        @as(i32, 0),
        try compareAlloc(testing.allocator, scientific, "0", "0.０"),
    );
    try expectOrder(scientific, "0.０", "0.0001");
    try expectOrder(scientific, "0.0０1", "0.009");
    try expectOrder(scientific, "-0.009", "-0.0０1");
}

test "digits: non-digit lookalikes are NOT folded" {
    const h: u32 = 0;
    // Specificity: fullwidth LETTERS and math letters must not become digits.
    // They stay CLASS_OTHER for now, i.e. after "zz".
    for ([_][]const u8{ "Ａ", "ａ", "𝐀", "𝔄" }) |c| {
        try expectOrder(h, "zz", c);
    }
}

// ── Phase 9: explicit '+' sign, and leading zeros as a default distinction ──

test "plus: '+' is NOT a sign in default mode" {
    const h: u32 = 0;
    // Default mode is a text sort; '+' stays punctuation, ranking below digits.
    try expectOrder(h, "+5", "5");
    try expectOrder(h, "+5", "+10"); // natural numeric after the punctuation
}

test "plus: '+' IS a sign under --dec / --sci" {
    for ([_]u32{ OPT_DECIMAL, OPT_SCIENTIFIC, OPT_SCIENTIFIC | OPT_DECIMAL }) |o| {
        // The bug this fixes: '+' used to rank below CLASS_NEG, so an explicit
        // plus sorted BELOW every negative.
        try expectOrder(o, "-3", "+5");
        try expectOrder(o, "-10", "+2");
        try expectOrder(o, "+5", "+10");
        // A signed positive is the same VALUE as the unsigned form.
        try testing.expectEqual(@as(i32, 0), try compareAlloc(testing.allocator, o, "+5", "5"));
    }
}

test "plus: a '+' not at offset 0, or not before a digit, stays punctuation" {
    const o = OPT_DECIMAL;
    try expectOrder(o, "peter+3", "peter+4");
    try expectOrder(o, "+abc", "+abd");
}

test "zeros: leading zeros are a REAL distinction in default mode" {
    const h: u32 = 0;
    // Previously "007" and "7" produced identical keys and compared EQUAL, so
    // the library's order was only a preorder and the CLI's raw-byte tie-break
    // was doing the work. More leading zeros now sorts first, for real.
    try expectOrder(h, "007", "07");
    try expectOrder(h, "07", "7");
    try expectOrder(h, "word007", "word7");
    try expectOrder(h, "00", "0");
    // ...without disturbing value ordering, which still dominates.
    try expectOrder(h, "007", "8");
    try expectOrder(h, "9", "010");
    // Negatives take the same tertiary weight, so this is a real ordering rather
    // than a tie the CLI's raw-byte fallback happens to resolve the same way.
    try expectOrder(h, "-007", "-7");
    try testing.expect((try compareAlloc(testing.allocator, h, "-007", "-7")) != 0);
}

test "zeros: leading zeros COLLIDE under --dec / --sci (they are equal values)" {
    for ([_]u32{ OPT_DECIMAL, OPT_SCIENTIFIC }) |o| {
        try testing.expectEqual(@as(i32, 0), try compareAlloc(testing.allocator, o, "007", "7"));
        try testing.expectEqual(@as(i32, 0), try compareAlloc(testing.allocator, o, "00", "0"));
    }
}

test "zeros: the distinction is TERTIARY — it never outranks value or letters" {
    const h: u32 = 0;
    // Equal primary+secondary is required before the zero count is consulted.
    try expectOrder(h, "007", "7"); // same value, zeros decide
    try expectOrder(h, "7", "07a"); // ...but a longer primary still wins first
    try expectOrder(h, "007a", "7a");
}

// ── Phase 8: scientific notation ──

test "scientific: OFF by default — 'e' is just a letter" {
    const h: u32 = 0;
    try expectOrder(h, "1e10", "2e5"); // digit run 1 < 2; the default reading
}

test "scientific: compares by VALUE, exponent first" {
    const s = OPT_SCIENTIFIC;
    try expectOrder(s, "2e5", "1e10"); // 200000 < 10000000000
    try expectOrder(s, "9e2", "1e3"); // 900 < 1000
    try expectOrder(s, "1.5e3", "1.6e3"); // same exponent, mantissa decides
    try expectOrder(s, "1e-10", "1e-5"); // negative exponents invert
    try expectOrder(s, "1e-5", "1e5");
    try expectOrder(s, "5e-1", "5e0");
    try expectOrder(s, "1E10", "2E10"); // capital E too
    try expectOrder(s, "1e+5", "1e+10"); // explicit + in the exponent
}

test "scientific: folded digits in exponents compare by value" {
    const s = OPT_SCIENTIFIC;
    // Sweep every digit style accepted by digitAt. Each spelling is 1e5,
    // which must outrank 2e4 regardless of its UTF-8 byte width.
    for ([_][]const u8{ "1e５", "1e𝟓", "1e𝟝", "1e𝟧", "1e𝟱", "1e𝟻" }) |folded| {
        try expectOrder(s, "2e4", folded);
    }
    try expectOrder(s, "2E４", "1E5");
    try expectOrder(s, "-1e５", "-2e4");
    try expectOrder(s, "1e-５", "1e-4");
}

test "scientific: normalizes plain numbers too, so mixed lists work" {
    const s = OPT_SCIENTIFIC;
    // A number without an exponent is just exponent 0 — normalizing it means a
    // list mixing both notations still orders correctly, rather than being UB.
    try expectOrder(s, "1234", "2e5"); // 1234 < 200000
    try expectOrder(s, "999", "1e3"); // 999 < 1000
    try expectOrder(s, "1e3", "1001"); // 1000 < 1001
    try expectOrder(s, "0.5", "5e0"); // 0.5 < 5
}

test "scientific: agrees with decimal mode on the cases they share" {
    const s = OPT_SCIENTIFIC;
    try expectOrder(s, "1.25", "1.5"); // varied precision
    try expectOrder(s, "0.45", "0.5");
    try expectOrder(s, "999999", "1000000");
    try expectOrder(s, "10.5", "10.55");
}

test "scientific: zero sorts below every positive, above every negative" {
    const s = OPT_SCIENTIFIC;
    try expectOrder(s, "0", "1e-999"); // zero is smaller than any tiny positive
    try expectOrder(s, "0", "0.001");
    try expectOrder(s, "-1e-999", "0"); // ...and bigger than any tiny negative
    try expectOrder(s, "0.0", "1");
    // Negative zero: every negative nonzero must sort below it. This is carried
    // by NEG_END, not by the zero flag — pinned here because mutation testing
    // showed the ordering was otherwise unverified.
    try expectOrder(s, "-5", "-0");
    try expectOrder(s, "-1e-999", "-0");
    try expectOrder(s, "-0", "0"); // matches the documented -0 < 0 caveat
}

test "scientific: negatives invert the WHOLE magnitude, exponent included" {
    const s = OPT_SCIENTIFIC;
    try expectOrder(s, "-1e10", "-2e5"); // -1e10 < -200000
    try expectOrder(s, "-1e3", "-9e2"); // -1000 < -900
    try expectOrder(s, "-1e-5", "-1e-10"); // closer to zero is bigger
    try expectOrder(s, "-1.6e3", "-1.5e3"); // mantissa inverts too
    try expectOrder(s, "-1.5", "-1"); // mantissa prefix case
    try expectOrder(s, "-5", "-1e-999");
}

test "scientific: --numeric == scientific + grouping absorption" {
    const n = OPT_SCIENTIFIC | OPT_DECIMAL;
    try expectOrder(n, "999,999", "1,000,000"); // grouping absorbed
    try expectOrder(n, "1,234", "2e5"); // ...and exponents understood
    try expectOrder(n, "2e5", "1,000,000");
}

test "scientific: OPT_DECIMAL_COMMA also moves the mantissa's decimal mark" {
    const n = OPT_SCIENTIFIC | OPT_DECIMAL | OPT_DECIMAL_COMMA;
    try expectOrder(n, "1,5e3", "1,6e3"); // ',' is the decimal mark here
    try expectOrder(n, "999.999", "1.000.000"); // '.' groups
}

test "scientific: a bare 'e' with no exponent digits is not an exponent" {
    const s = OPT_SCIENTIFIC;
    // "1e" and "3employees" must not swallow the letter as an exponent marker.
    try expectOrder(s, "1e", "2e");
    try expectOrder(s, "3employees", "4employees");
    try expectOrder(s, "1efg", "2efg");
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

test "decimal: OPT_DECIMAL makes every digit run's first '.' a decimal point" {
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

test "numeric: default and decimal modes share the integer primary payload" {
    for ([_][]const u8{ "0", "007", "123", "１２３", "𝟙𝟚𝟛" }) |s| {
        const plain = try sortKeyAlloc(testing.allocator, 0, s);
        defer testing.allocator.free(plain);
        const decimal = try sortKeyAlloc(testing.allocator, OPT_DECIMAL, s);
        defer testing.allocator.free(decimal);
        const plain_end = std.mem.indexOfScalar(u8, plain, SEP).?;
        const decimal_end = std.mem.indexOfScalar(u8, decimal, SEP).?;
        try testing.expectEqualSlices(u8, plain[0..plain_end], decimal[0..decimal_end]);
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

test "house: Romanian letters and legacy spellings stay letter-class" {
    // These used to fall through to CLASS_OTHER (after every letter). Their
    // primary positions and canonical equivalence are asserted above.
    for ([_][]const u8{ "ă", "â", "î", "ș", "ț", "ş", "ţ", "s\u{0326}", "t\u{0326}", "Ș", "Ț", "S\u{0326}", "T\u{0326}" }) |s| {
        try testing.expect(try collatesAsLetter(s));
    }
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
