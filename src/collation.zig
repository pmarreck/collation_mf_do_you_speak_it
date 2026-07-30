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

// ─── Sort-key structural bytes ───────────────────────────────────────────
const TERM: u8 = 0x00; // whole-key terminator (< everything)
const SEP: u8 = 0x01; // level separator (< all content, > terminator)

// Primary class ranks. Widely spaced, all >= 0x02. This ordering IS the
// "structural-first" house rule: whitespace < punctuation < digit < letter.
const CLASS_WS: u8 = 0x10;
const CLASS_PUNCT: u8 = 0x20;
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

/// Append the primary bytes for one ASCII digit run, length-prefixed with the
/// count of significant digits so bytewise comparison matches numeric value
/// (the natural-sort technique: fewer significant digits => smaller number).
fn pushNumericPrimary(l1: *L1, alloc: std.mem.Allocator, run: []const u8) !void {
    var start: usize = 0;
    while (start < run.len and run[start] == '0') start += 1;
    const sig = run[start..]; // significant digits, no leading zeros (may be empty => value 0)
    const capped: usize = if (sig.len > 250) 250 else sig.len;
    try l1.append(alloc, CLASS_DIGIT);
    try l1.append(alloc, WEIGHT_BASE + @as(u8, @intCast(capped)));
    for (sig[0..capped]) |d| try l1.append(alloc, WEIGHT_BASE + (d - '0'));
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
    while (i < s.len) {
        const b = s[i];

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
    const alphabet = "abcABC 12.é�zñ-_ßœæĳășțŀ";
    var a_buf: [16]u8 = undefined;
    var b_buf: [16]u8 = undefined;

    for ([_]u32{ 0, OPT_CODE_POINT }) |opts| {
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
