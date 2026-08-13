//! Property fuzzer for the collation core.
//!
//! Not a "does it crash" fuzzer — a wrong ORDER never crashes, so a crash-only
//! fuzzer sails straight past every defect this library can actually have.
//!
//! IMPORTANT, learned by mutation-testing this file: the algebraic order laws
//! are nearly VACUOUS here. `memcmp` is a total order over ANY bytes, so
//! reflexivity, antisymmetry and transitivity hold automatically no matter what
//! the key builder emits — a key builder can be badly wrong and satisfy all
//! three. Likewise "sort-key order == compare order" compares two paths that
//! both run through the same builder, so it cannot falsify that builder. They
//! are kept as cheap regression guards, not as the substance.
//!
//! The properties that can actually FAIL, each verified to kill an injected bug:
//!
//!   STRUCTURAL
//!     |L2| == |L3|              every element owes exactly one weight per level;
//!                               catches a level desync  (kills: expansion that
//!                               emits two L2 entries and one L3 entry)
//!   SEMANTIC, against oracles this file computes independently
//!     numeric order             digit strings must order by (significant-digit
//!                               count, then lexicographic)  (kills: a wrong
//!                               length prefix)
//!     case-fold primary         upper/lower-casing ASCII must not change L1
//!     expansion adjacency       a ligature shares L1 AND L2 with its spelling
//!                               (kills: case leaking into the primary level)
//!   HYGIENE
//!     keys NUL-terminated, no interior NUL   (RULES.md #4)
//!
//! Inputs come in four shapes — structured, raw bytes (invalid UTF-8), ASCII
//! digits, and well-formed folded digits. The two numeric shapes exist because
//! the numeric oracle only fires on pure digit strings, which random byte
//! generation essentially never produces.

const std = @import("std");
const collation = @import("collation.zig");

const OPTION_SETS = [_]u32{
    0,
    collation.OPT_CODE_POINT,
    collation.OPT_DECIMAL,
    collation.OPT_DECIMAL | collation.OPT_DECIMAL_COMMA,
    collation.OPT_SCIENTIFIC,
    collation.OPT_SCIENTIFIC | collation.OPT_DECIMAL,
    collation.OPT_ROMAN,
    collation.OPT_ROMAN | collation.OPT_DECIMAL,
};

/// Bytes chosen to hit every branch: digits of three widths, all the group
/// separators, sign characters, Roman letters, ligatures, an expansion, a
/// combining-mark lead byte, and CJK.
const INTERESTING = "0123456789 .,'_-+eE" ++
    "IVXLCDMivxlcdm" ++
    "abzABZ" ++
    "é ñ ß œ æ ĳ ŀ ă ș ț" ++
    "½ Ⅷ ™ ⅒" ++
    "１２３ 𝟑 𝟚" ++
    "中 € \t\n";

/// Render bytes as lowercase hex into `buf` so a failure is reproducible even
/// when the input is invalid UTF-8 that a terminal would mangle.
fn hex(buf: []u8, s: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    var n: usize = 0;
    for (s) |byte| {
        if (n + 2 > buf.len) break;
        buf[n] = digits[byte >> 4];
        buf[n + 1] = digits[byte & 0x0F];
        n += 2;
    }
    return buf[0..n];
}

/// Read a decimal environment variable via libc, which is stable across the
/// std API churn and is already linked here.
fn envUsize(name: [*:0]const u8, dflt: usize) usize {
    const raw = std.c.getenv(name) orelse return dflt;
    return std.fmt.parseInt(usize, std.mem.span(raw), 10) catch dflt;
}

fn cmp(alloc: std.mem.Allocator, opts: u32, a: []const u8, b: []const u8) !i32 {
    return collation.compareAlloc(alloc, opts, a, b);
}

fn checkPair(alloc: std.mem.Allocator, opts: u32, a: []const u8, b: []const u8) !void {
    const ab = try cmp(alloc, opts, a, b);
    const ba = try cmp(alloc, opts, b, a);

    // 3. reflexivity
    if (try cmp(alloc, opts, a, a) != 0) return error.NotReflexive;

    // 4. antisymmetry
    if (ab != -ba) return error.NotAntisymmetric;

    // 1. sort-key order == compare order
    const ka = try collation.sortKeyAlloc(alloc, opts, a);
    defer alloc.free(ka);
    const kb = try collation.sortKeyAlloc(alloc, opts, b);
    defer alloc.free(kb);
    const key_order: i32 = switch (std.mem.order(u8, ka, kb)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    if (key_order != ab) return error.KeyOrderDisagrees;

    // 2. C-safe keys. Code-point mode has the stronger exact-shape contract:
    // raw input followed by the public API's trailing NUL.
    for ([_]struct { key: []const u8, input: []const u8 }{
        .{ .key = ka, .input = a },
        .{ .key = kb, .input = b },
    }) |item| {
        const k = item.key;
        if (opts & collation.OPT_CODE_POINT != 0) {
            if (k.len != item.input.len + 1) return error.CodePointKeyLength;
            if (!std.mem.eql(u8, k[0..item.input.len], item.input)) return error.CodePointKeyPayload;
            if (k[k.len - 1] != 0) return error.KeyNotTerminated;
            continue;
        }
        if (k.len == 0) return error.EmptyKey;
        if (k[k.len - 1] != 0) return error.KeyNotTerminated;
        for (k[0 .. k.len - 1]) |byte| if (byte == 0) return error.InteriorNul;
    }
}

/// Split a house-style key into its three levels: L1 ++ SEP ++ L2 ++ SEP ++ L3
/// ++ TERM.
fn levels(k: []const u8) ?struct { l1: []const u8, l2: []const u8, l3: []const u8 } {
    const s1 = std.mem.indexOfScalar(u8, k, 0x01) orelse return null;
    const s2 = std.mem.indexOfScalarPos(u8, k, s1 + 1, 0x01) orelse return null;
    if (k.len == 0 or k[k.len - 1] != 0) return null;
    return .{ .l1 = k[0..s1], .l2 = k[s1 + 1 .. s2], .l3 = k[s2 + 1 .. k.len - 1] };
}

/// STRUCTURAL: every collation element contributes exactly one secondary and one
/// tertiary weight, so a key's L2 and L3 must be the same length. This is the
/// property that catches a level DESYNC — an expansion emitting two L2 entries
/// but one L3 entry, say — which the ordering laws cannot catch, because memcmp
/// yields a perfectly valid total order over any bytes whatsoever.
fn checkLevelAlignment(alloc: std.mem.Allocator, opts: u32, s: []const u8) !void {
    if (opts & collation.OPT_CODE_POINT != 0) return; // raw bytes, no levels
    const k = try collation.sortKeyAlloc(alloc, opts, s);
    defer alloc.free(k);
    const lv = levels(k) orelse return error.MalformedKey;
    if (lv.l2.len != lv.l3.len) return error.LevelDesync;
}

const ORACLE_DIGIT_BASES = [_]u21{
    '0', 0xFF10, 0x1D7CE, 0x1D7D8, 0x1D7E2, 0x1D7EC, 0x1D7F6,
};

fn oracleDigitAt(s: []const u8, start: usize) ?struct { value: u8, len: usize } {
    const lead = s[start];
    const len = std.unicode.utf8ByteSequenceLength(lead) catch return null;
    if (start + len > s.len) return null;
    const cp = std.unicode.utf8Decode(s[start .. start + len]) catch return null;
    for (ORACLE_DIGIT_BASES) |base| {
        if (cp >= base and cp < base + 10) return .{ .value = @intCast(cp - base), .len = len };
    }
    return null;
}

fn oracleDigits(s: []const u8, out: []u8) ?[]const u8 {
    var source: usize = 0;
    var count: usize = 0;
    while (source < s.len) {
        const digit = oracleDigitAt(s, source) orelse return null;
        if (count == out.len) return null;
        out[count] = digit.value;
        count += 1;
        source += digit.len;
    }
    return if (count == 0) null else out[0..count];
}

/// SEMANTIC, with an independently decoded oracle: pure ASCII/fullwidth/math
/// digit strings must order by significant-digit count and then digit values.
fn checkNumericOracle(alloc: std.mem.Allocator, a: []const u8, b: []const u8) !void {
    var a_digits_buf: [96]u8 = undefined;
    var b_digits_buf: [96]u8 = undefined;
    const a_digits = oracleDigits(a, &a_digits_buf) orelse return error.NotOracleDigits;
    const b_digits = oracleDigits(b, &b_digits_buf) orelse return error.NotOracleDigits;
    var ai: usize = 0;
    var bi: usize = 0;
    while (ai < a_digits.len and a_digits[ai] == 0) ai += 1;
    while (bi < b_digits.len and b_digits[bi] == 0) bi += 1;
    const sa = a_digits[ai..];
    const sb = b_digits[bi..];
    const want: i32 = if (sa.len != sb.len)
        (if (sa.len < sb.len) @as(i32, -1) else 1)
    else switch (std.mem.order(u8, sa, sb)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
    const got = try collation.compareAlloc(alloc, 0, a, b);
    // Equal VALUES may still differ by leading-zero count, which is a tertiary
    // distinction by design; only a sign disagreement is a defect.
    if (want != 0 and got != want) return error.NumericOrderWrong;
}

/// SEMANTIC: case is a tertiary distinction, so upper- and lower-casing an ASCII
/// string must leave its PRIMARY level untouched.
fn checkCaseFold(alloc: std.mem.Allocator, s: []const u8, upper: []u8) !void {
    for (s, 0..) |c, i| upper[i] = if (c >= 'a' and c <= 'z') c - 32 else c;
    const ka = try collation.sortKeyAlloc(alloc, 0, s);
    defer alloc.free(ka);
    const kb = try collation.sortKeyAlloc(alloc, 0, upper[0..s.len]);
    defer alloc.free(kb);
    const la = levels(ka) orelse return error.MalformedKey;
    const lb = levels(kb) orelse return error.MalformedKey;
    if (!std.mem.eql(u8, la.l1, lb.l1)) return error.CaseAffectedPrimary;
}

/// SEMANTIC: a compatibility expansion must share PRIMARY and SECONDARY with its
/// spelled-out form — that is what makes the two sort adjacent.
const EXPANSIONS = [_][2][]const u8{
    .{ "ß", "ss" },   .{ "œ", "oe" },  .{ "æ", "ae" },
    .{ "ĳ", "ij" },   .{ "Ⅷ", "VIII" }, .{ "½", "1/2" },
    .{ "™", "TM" },   .{ "⅒", "1/10" },
};

fn checkExpansions(alloc: std.mem.Allocator) !void {
    for (EXPANSIONS) |pair| {
        const ka = try collation.sortKeyAlloc(alloc, 0, pair[0]);
        defer alloc.free(ka);
        const kb = try collation.sortKeyAlloc(alloc, 0, pair[1]);
        defer alloc.free(kb);
        const la = levels(ka) orelse return error.MalformedKey;
        const lb = levels(kb) orelse return error.MalformedKey;
        if (!std.mem.eql(u8, la.l1, lb.l1)) return error.ExpansionPrimaryDiffers;
        if (!std.mem.eql(u8, la.l2, lb.l2)) return error.ExpansionSecondaryDiffers;
    }
}

/// Four generation modes, because the semantic oracles only fire on inputs of a
/// particular SHAPE. Left to chance, a pure-digit string essentially never
/// appears, so the numeric oracle sat idle and a broken length prefix went
/// undetected — mutation testing found exactly that.
const Shape = enum { interesting, raw_bytes, digits_only, folded_digits };

fn genFoldedDigits(rng: std.Random, buf: []u8) []u8 {
    const digit_count = rng.intRangeAtMost(usize, 0, buf.len / 4);
    var end: usize = 0;
    for (0..digit_count) |_| {
        const base = ORACLE_DIGIT_BASES[rng.uintLessThan(usize, ORACLE_DIGIT_BASES.len)];
        const cp: u21 = base + rng.uintLessThan(u8, 10);
        end += std.unicode.utf8Encode(cp, buf[end..]) catch unreachable;
    }
    return buf[0..end];
}

fn genString(rng: std.Random, buf: []u8, shape: Shape) []u8 {
    if (shape == .folded_digits) return genFoldedDigits(rng, buf);
    const n = rng.intRangeAtMost(usize, 0, buf.len);
    switch (shape) {
        .interesting => for (0..n) |i| {
            buf[i] = INTERESTING[rng.intRangeLessThan(usize, 0, INTERESTING.len)];
        },
        .raw_bytes => rng.bytes(buf[0..n]),
        .digits_only => for (0..n) |i| {
            buf[i] = '0' + rng.uintLessThan(u8, 10);
        },
        .folded_digits => unreachable,
    }
    return buf[0..n];
}

fn pickShape(rng: std.Random) Shape {
    return switch (rng.uintLessThan(u8, 4)) {
        0 => .interesting,
        1 => .raw_bytes,
        2 => .digits_only,
        else => .folded_digits,
    };
}

pub fn main() !void {
    const alloc = std.heap.c_allocator;

    // Iterations and seed arrive via the environment so a failing run is exactly
    // reproducible: rerun ./fuzz with the same FUZZ_SEED.
    const iterations = envUsize("FUZZ_ITERATIONS", 200_000);
    const seed: u64 = (envUsize("FUZZ_SEED", 0xC0FFEE));

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    std.debug.print("fuzzing {d} iterations, seed 0x{X}, {d} option sets\n", .{ iterations, seed, OPTION_SETS.len });

    var hex_a: [256]u8 = undefined;
    var hex_b: [256]u8 = undefined;
    var hex_c: [256]u8 = undefined;
    var upper_buf: [96]u8 = undefined;
    var a_buf: [96]u8 = undefined;
    var b_buf: [96]u8 = undefined;
    var c_buf: [96]u8 = undefined;
    var checked: usize = 0;

    checkExpansions(alloc) catch |e| {
        std.debug.print("FAIL {s} — a compatibility expansion no longer shares primary+secondary with its spelling\n", .{@errorName(e)});
        std.process.exit(1);
    };

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        // a and b share a shape often, so paired oracles (numeric) actually fire.
        const shape = pickShape(rng);
        const a = genString(rng, &a_buf, shape);
        const b = genString(rng, &b_buf, if (rng.uintLessThan(u8, 4) == 0) pickShape(rng) else shape);
        const c = genString(rng, &c_buf, shape);
        for (OPTION_SETS) |opts| {
            checkPair(alloc, opts, a, b) catch |e| {
                std.debug.print(
                    "\nFAIL {s}\n  opts=0x{X}\n  a={s}\n  b={s}\n  seed=0x{X} iter={d}\n",
                    .{ @errorName(e), opts, hex(&hex_a, a), hex(&hex_b, b), seed, i },
                );
                std.process.exit(1);
            };

            // 5. transitivity, over the sorted triple
            const ab = try cmp(alloc, opts, a, b);
            const bc = try cmp(alloc, opts, b, c);
            const ac = try cmp(alloc, opts, a, c);
            if (ab <= 0 and bc <= 0 and ac > 0) {
                std.debug.print(
                    "\nFAIL Transitivity\n  opts=0x{X}\n  a={s}\n  b={s}\n  c={s}\n  seed=0x{X} iter={d}\n",
                    .{
                        opts,
                        hex(&hex_a, a),
                        hex(&hex_b, b),
                        hex(&hex_c, c),
                        seed,
                        i,
                    },
                );
                std.process.exit(1);
            }
            // STRUCTURAL: levels must stay aligned. Unlike the ordering laws
            // above, this one can actually fail.
            checkLevelAlignment(alloc, opts, a) catch |e| {
                std.debug.print("\nFAIL {s}\n  opts=0x{X}\n  a={s}\n  seed=0x{X} iter={d}\n", .{ @errorName(e), opts, hex(&hex_a, a), seed, i });
                std.process.exit(1);
            };
            checked += 1;
        }

        // Semantic properties, checked against oracles the key builder did not
        // write. Digit-only strings drive the numeric oracle; ASCII strings
        // drive the case-fold invariant.
        var a_digit_buf: [96]u8 = undefined;
        var b_digit_buf: [96]u8 = undefined;
        if (oracleDigits(a, &a_digit_buf) != null and oracleDigits(b, &b_digit_buf) != null) {
            checkNumericOracle(alloc, a, b) catch |e| {
                std.debug.print("\nFAIL {s}\n  a={s}\n  b={s}\n  seed=0x{X} iter={d}\n", .{ @errorName(e), hex(&hex_a, a), hex(&hex_b, b), seed, i });
                std.process.exit(1);
            };
            checked += 1;
        }
        var ascii = true;
        for (a) |ch| {
            if (ch >= 0x80) {
                ascii = false;
                break;
            }
        }
        if (ascii) {
            checkCaseFold(alloc, a, &upper_buf) catch |e| {
                std.debug.print("\nFAIL {s}\n  a={s}\n  seed=0x{X} iter={d}\n", .{ @errorName(e), hex(&hex_a, a), seed, i });
                std.process.exit(1);
            };
            checked += 1;
        }
        if (i % 20_000 == 0 and i > 0) {
            std.debug.print("  {d}/{d}\n", .{ i, iterations });
        }
    }

    std.debug.print("OK — {d} iterations x {d} option sets = {d} property checks\n", .{ iterations, OPTION_SETS.len, checked });
}
