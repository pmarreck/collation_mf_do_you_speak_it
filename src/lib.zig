//! collation_mf_do_you_speak_it — C FFI surface.
//!
//! The pure collation algorithm lives in `collation.zig` (no I/O). This file is
//! the ports-and-adapters boundary: `export fn` entry points with the C ABI,
//! modeled on ICU4C's `ucol_*` collator API but UTF-8-native.
//!
//! The C CLI (`cli/main.c`) and every other consumer go through these symbols;
//! that dogfoods the FFI that downstream users depend on.

const std = @import("std");
pub const collation = @import("collation.zig");

test {
    // Pull collation.zig's tests into the `zig build test` run.
    std.testing.refAllDecls(@This());
    _ = collation;
}

// ─── Version ─────────────────────────────────────────────────────────────
pub const Version = struct {
    pub const major: u8 = 0;
    pub const minor: u8 = 1;
    pub const patch: u8 = 0;
    pub const string: [:0]const u8 = "0.1.0";
};

// ─── Opaque collator handle ──────────────────────────────────────────────
const Collator = struct {
    options: u32,
};

const c_alloc = std.heap.c_allocator;

// ─── C FFI exports ───────────────────────────────────────────────────────

/// Return the library version as a NUL-terminated string. Stable forever.
export fn collation_mf_version() callconv(.c) [*:0]const u8 {
    return Version.string.ptr;
}

/// Open a collator for the given options bitmask (analog of `ucol_open`).
export fn collation_mf_open(options: u32) callconv(.c) ?*Collator {
    const coll = c_alloc.create(Collator) catch return null;
    coll.* = .{ .options = options };
    return coll;
}

/// Close/free a collator. NULL-safe.
export fn collation_mf_close(coll: ?*Collator) callconv(.c) void {
    if (coll) |p| c_alloc.destroy(p);
}

/// Compare two UTF-8 byte strings (analog of `ucol_strcollUTF8`). -1 / 0 / 1.
export fn collation_mf_strcoll8(
    coll: ?*const Collator,
    a: [*]const u8,
    alen: usize,
    b: [*]const u8,
    blen: usize,
) callconv(.c) i32 {
    const c = coll orelse return 0;
    return collation.compareAlloc(c_alloc, c.options, a[0..alen], b[0..blen]) catch 0;
}

/// Write a binary sort key for `s` into `out` (analog of `ucol_getSortKey`).
/// Returns the total key length (including trailing NUL); may exceed out_cap.
export fn collation_mf_get_sort_key(
    coll: ?*const Collator,
    s: [*]const u8,
    slen: usize,
    out: ?[*]u8,
    out_cap: usize,
) callconv(.c) usize {
    const c = coll orelse return 0;
    const key = collation.sortKeyAlloc(c_alloc, c.options, s[0..slen]) catch return 0;
    defer c_alloc.free(key);
    if (out) |dst| {
        const n = @min(key.len, out_cap);
        if (n > 0) @memcpy(dst[0..n], key[0..n]);
    }
    return key.len;
}

/// POSIX-shaped `strcoll` analog using default house-style options.
export fn collation_mf_strcoll(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) i32 {
    return collation.compareAlloc(c_alloc, 0, std.mem.span(a), std.mem.span(b)) catch 0;
}

/// POSIX-shaped `strxfrm` analog: transform `src` into a sort key in `dst`.
/// Returns the length the full key needs excluding the trailing NUL.
export fn collation_mf_strxfrm(dst: ?[*]u8, src: [*:0]const u8, n: usize) callconv(.c) usize {
    const s = std.mem.span(src);
    const key = collation.sortKeyAlloc(c_alloc, 0, s) catch return 0;
    defer c_alloc.free(key);
    // key already ends in a NUL terminator; report length excluding it.
    const full = if (key.len > 0) key.len - 1 else 0;
    if (dst) |d| {
        if (n > 0) {
            const copy = @min(key.len, n);
            @memcpy(d[0..copy], key[0..copy]);
            if (copy < key.len) d[n - 1] = 0; // ensure termination on truncation
        }
    }
    return full;
}

// ─── FFI smoke tests (exercise the exported ABI in-process) ──────────────

const testing = std.testing;

test "ffi: version is well-formed" {
    const v = std.mem.sliceTo(collation_mf_version(), 0);
    try testing.expectEqualStrings("0.1.0", v);
}

test "ffi: open/strcoll8/close round trip (house style)" {
    const coll = collation_mf_open(0) orelse return error.OpenFailed;
    defer collation_mf_close(coll);
    const a = "file2";
    const b = "file10";
    try testing.expectEqual(@as(i32, -1), collation_mf_strcoll8(coll, a.ptr, a.len, b.ptr, b.len));
    try testing.expectEqual(@as(i32, 1), collation_mf_strcoll8(coll, b.ptr, b.len, a.ptr, a.len));
}

test "ffi: get_sort_key memcmp order matches strcoll8" {
    const coll = collation_mf_open(0) orelse return error.OpenFailed;
    defer collation_mf_close(coll);
    var ka: [64]u8 = undefined;
    var kb: [64]u8 = undefined;
    const a = "apple";
    const b = "Apple";
    const na = collation_mf_get_sort_key(coll, a.ptr, a.len, &ka, ka.len);
    const nb = collation_mf_get_sort_key(coll, b.ptr, b.len, &kb, kb.len);
    try testing.expect(na > 0 and nb > 0);
    const cmp = collation_mf_strcoll8(coll, a.ptr, a.len, b.ptr, b.len);
    const key_cmp = std.mem.order(u8, ka[0..na], kb[0..nb]);
    try testing.expectEqual(@as(i32, -1), cmp);
    try testing.expectEqual(std.math.Order.lt, key_cmp);
}

test "ffi: code-point mode == raw byte order" {
    const coll = collation_mf_open(collation.OPT_CODE_POINT) orelse return error.OpenFailed;
    defer collation_mf_close(coll);
    const a = "Zebra";
    const b = "apple";
    // 'Z' (0x5A) < 'a' (0x61) in byte order.
    try testing.expectEqual(@as(i32, -1), collation_mf_strcoll8(coll, a.ptr, a.len, b.ptr, b.len));
}

test "ffi: get_sort_key length probe (out=null, cap=0)" {
    const coll = collation_mf_open(0) orelse return error.OpenFailed;
    defer collation_mf_close(coll);
    const s = "hello";
    const needed = collation_mf_get_sort_key(coll, s.ptr, s.len, null, 0);
    try testing.expect(needed > 0);
}
