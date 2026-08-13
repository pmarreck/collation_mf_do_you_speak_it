//! romantic_collation — C FFI surface.
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
    pub const string: [:0]const u8 = std.fmt.comptimePrint(
        "{d}.{d}.{d}",
        .{ major, minor, patch },
    );
};

// ─── Opaque collator handle ──────────────────────────────────────────────
const Collator = struct {
    options: u32,
    allocator: std.mem.Allocator,
};

const c_alloc = std.heap.c_allocator;

pub const ABI_VERSION: u32 = 1;
const KNOWN_OPTIONS: u32 = (1 << 7) - 1;

pub const Status = enum(i32) {
    ok = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    buffer_too_small = 3,
    unsupported_abi = 4,
    unsupported_option = 5,
};

pub const Config = extern struct {
    struct_size: usize,
    abi_version: u32,
    options: u32,

    pub fn init(options: u32) Config {
        return .{
            .struct_size = @sizeOf(Config),
            .abi_version = ABI_VERSION,
            .options = options,
        };
    }
};

// ─── C FFI exports ───────────────────────────────────────────────────────

/// Return the library version as a NUL-terminated string. Stable forever.
export fn rcol_version() callconv(.c) [*:0]const u8 {
    return Version.string.ptr;
}

fn openWithAllocator(allocator: std.mem.Allocator, config: ?*const Config, out: ?*?*Collator) Status {
    const out_collator = out orelse return .invalid_argument;
    out_collator.* = null;
    const cfg = config orelse return .invalid_argument;
    const required_size = @offsetOf(Config, "options") + @sizeOf(u32);
    if (cfg.struct_size < required_size) return .invalid_argument;
    if (cfg.abi_version != ABI_VERSION) return .unsupported_abi;
    if (cfg.options & ~KNOWN_OPTIONS != 0) return .unsupported_option;

    const coll = allocator.create(Collator) catch return .out_of_memory;
    coll.* = .{ .options = cfg.options, .allocator = allocator };
    out_collator.* = coll;
    return .ok;
}

/// Open a collator through a size-versioned configuration structure.
export fn rcol_open(config: ?*const Config, out: ?*?*Collator) callconv(.c) Status {
    return openWithAllocator(c_alloc, config, out);
}

/// Close/free a collator. NULL-safe.
export fn rcol_close(coll: ?*Collator) callconv(.c) void {
    if (coll) |p| p.allocator.destroy(p);
}

fn checkedBytes(ptr: ?[*]const u8, len: usize) ?[]const u8 {
    if (ptr) |p| return p[0..len];
    return if (len == 0) &.{} else null;
}

/// Compare UTF-8 strings and return the ordering through an out-parameter.
export fn rcol_compare_utf8(
    coll: ?*const Collator,
    a: ?[*]const u8,
    alen: usize,
    b: ?[*]const u8,
    blen: usize,
    out_order: ?*i32,
) callconv(.c) Status {
    const c = coll orelse return .invalid_argument;
    const result = out_order orelse return .invalid_argument;
    const a_bytes = checkedBytes(a, alen) orelse return .invalid_argument;
    const b_bytes = checkedBytes(b, blen) orelse return .invalid_argument;
    const order = collation.compareAlloc(c.allocator, c.options, a_bytes, b_bytes) catch return .out_of_memory;
    result.* = order;
    return .ok;
}

/// Write a complete binary sort key or report its required size separately.
export fn rcol_sort_key_utf8(
    coll: ?*const Collator,
    s: ?[*]const u8,
    slen: usize,
    out: ?[*]u8,
    out_cap: usize,
    out_required: ?*usize,
) callconv(.c) Status {
    const required = out_required orelse return .invalid_argument;
    required.* = 0;
    const c = coll orelse return .invalid_argument;
    const bytes = checkedBytes(s, slen) orelse return .invalid_argument;
    if (out == null and out_cap != 0) return .invalid_argument;

    const key = collation.sortKeyAlloc(c.allocator, c.options, bytes) catch return .out_of_memory;
    defer c.allocator.free(key);
    required.* = key.len;
    if (out_cap == 0) return .ok;
    if (out_cap < key.len) return .buffer_too_small;
    @memcpy(out.?[0..key.len], key);
    return .ok;
}

/// Return a stable, statically allocated name for a public status code.
export fn rcol_status_name(status_value: i32) callconv(.c) [*:0]const u8 {
    const status = std.enums.fromInt(Status, status_value) orelse return "unknown status";
    return switch (status) {
        .ok => "ok",
        .invalid_argument => "invalid argument",
        .out_of_memory => "out of memory",
        .buffer_too_small => "buffer too small",
        .unsupported_abi => "unsupported ABI version",
        .unsupported_option => "unsupported option",
    };
}

// ─── FFI smoke tests (exercise the exported ABI in-process) ──────────────

const testing = std.testing;

test "ffi: version is well-formed" {
    const v = std.mem.sliceTo(rcol_version(), 0);
    try testing.expectEqualStrings("0.1.0", v);
}

test "ffi: checked API keeps status separate from comparison results" {
    var config = Config.init(0);
    var coll: ?*Collator = null;
    try testing.expectEqual(Status.ok, rcol_open(&config, &coll));
    defer rcol_close(coll);

    var order: i32 = 99;
    const a = "file2";
    const b = "file10";
    try testing.expectEqual(
        Status.ok,
        rcol_compare_utf8(coll, a.ptr, a.len, b.ptr, b.len, &order),
    );
    try testing.expectEqual(@as(i32, -1), order);

    order = 99;
    try testing.expectEqual(
        Status.invalid_argument,
        rcol_compare_utf8(null, a.ptr, a.len, b.ptr, b.len, &order),
    );
    try testing.expectEqual(@as(i32, 99), order);
}

fn testOpen(options: u32) !*Collator {
    var config = Config.init(options);
    var coll: ?*Collator = null;
    try testing.expectEqual(Status.ok, rcol_open(&config, &coll));
    return coll orelse error.OpenFailed;
}

fn testCompare(coll: *const Collator, a: []const u8, b: []const u8) !i32 {
    var order: i32 = 99;
    try testing.expectEqual(Status.ok, rcol_compare_utf8(coll, a.ptr, a.len, b.ptr, b.len, &order));
    return order;
}

test "ffi: open validates configuration without publishing a handle" {
    var coll: ?*Collator = @ptrFromInt(@alignOf(Collator));
    try testing.expectEqual(Status.invalid_argument, rcol_open(null, &coll));
    try testing.expectEqual(@as(?*Collator, null), coll);
    try testing.expectEqual(Status.invalid_argument, rcol_open(null, null));

    var config = Config.init(0);
    config.struct_size = @offsetOf(Config, "options");
    try testing.expectEqual(Status.invalid_argument, rcol_open(&config, &coll));
    try testing.expectEqual(@as(?*Collator, null), coll);

    config = Config.init(0);
    config.abi_version += 1;
    try testing.expectEqual(Status.unsupported_abi, rcol_open(&config, &coll));
    try testing.expectEqual(@as(?*Collator, null), coll);

    config = Config.init(1 << 31);
    try testing.expectEqual(Status.unsupported_option, rcol_open(&config, &coll));
    try testing.expectEqual(@as(?*Collator, null), coll);

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    config = Config.init(0);
    try testing.expectEqual(Status.out_of_memory, openWithAllocator(failing.allocator(), &config, &coll));
    try testing.expectEqual(@as(?*Collator, null), coll);
}

test "ffi: Romanian canonical spellings compare equal" {
    const coll = try testOpen(0);
    defer rcol_close(coll);
    for ([_][4][]const u8{
        .{ "ș", "ş", "s\u{0326}", "s\u{0327}" },
        .{ "ț", "ţ", "t\u{0326}", "t\u{0327}" },
        .{ "Ș", "Ş", "S\u{0326}", "S\u{0327}" },
        .{ "Ț", "Ţ", "T\u{0326}", "T\u{0327}" },
    }) |spellings| {
        for (spellings[1..]) |other| {
            try testing.expectEqual(
                @as(i32, 0),
                try testCompare(coll, spellings[0], other),
            );
        }
    }
}

test "ffi: sort-key order matches checked comparison order" {
    const coll = try testOpen(0);
    defer rcol_close(coll);
    var ka: [64]u8 = undefined;
    var kb: [64]u8 = undefined;
    const a = "apple";
    const b = "Apple";
    var na: usize = 0;
    var nb: usize = 0;
    try testing.expectEqual(Status.ok, rcol_sort_key_utf8(coll, a.ptr, a.len, &ka, ka.len, &na));
    try testing.expectEqual(Status.ok, rcol_sort_key_utf8(coll, b.ptr, b.len, &kb, kb.len, &nb));
    try testing.expect(na > 0 and nb > 0);
    const cmp = try testCompare(coll, a, b);
    const key_cmp = std.mem.order(u8, ka[0..na], kb[0..nb]);
    try testing.expectEqual(@as(i32, -1), cmp);
    try testing.expectEqual(std.math.Order.lt, key_cmp);
}

test "ffi: code-point mode == raw byte order" {
    const coll = try testOpen(collation.OPT_CODE_POINT);
    defer rcol_close(coll);
    const a = "Zebra";
    const b = "apple";
    // 'Z' (0x5A) < 'a' (0x61) in byte order.
    try testing.expectEqual(@as(i32, -1), try testCompare(coll, a, b));
}

test "ffi: code-point sort key includes its promised NUL terminator" {
    const coll = try testOpen(collation.OPT_CODE_POINT);
    defer rcol_close(coll);
    const s = "Zebra";
    var key: [s.len + 1]u8 = undefined;
    var n: usize = 0;
    try testing.expectEqual(Status.ok, rcol_sort_key_utf8(coll, s.ptr, s.len, &key, key.len, &n));
    try testing.expectEqual(s.len + 1, n);
    try testing.expectEqualStrings(s, key[0..s.len]);
    try testing.expectEqual(@as(u8, 0), key[s.len]);
}

test "ffi: sort-key length probe accepts NULL for empty strings" {
    const coll = try testOpen(0);
    defer rcol_close(coll);
    var needed: usize = 0;
    try testing.expectEqual(Status.ok, rcol_sort_key_utf8(coll, null, 0, null, 0, &needed));
    try testing.expect(needed > 0);
}

test "ffi: undersized sort-key buffers are reported and left untouched" {
    const coll = try testOpen(0);
    defer rcol_close(coll);
    const s = "file10";
    var full: [128]u8 = undefined;
    var needed: usize = 0;
    try testing.expectEqual(Status.ok, rcol_sort_key_utf8(coll, s.ptr, s.len, &full, full.len, &needed));
    try testing.expect(needed > 1 and needed < full.len);

    var partial: [128]u8 = undefined;
    for (1..needed) |cap| {
        @memset(&partial, 0xAA);
        var reported: usize = 0;
        try testing.expectEqual(Status.buffer_too_small, rcol_sort_key_utf8(coll, s.ptr, s.len, &partial, cap, &reported));
        try testing.expectEqual(needed, reported);
        try testing.expectEqualSlices(u8, &([_]u8{0xAA} ** partial.len), &partial);
    }
}

test "ffi: invalid pointers and allocation failures have explicit statuses" {
    const coll = try testOpen(0);
    defer rcol_close(coll);

    var order: i32 = 77;
    try testing.expectEqual(Status.invalid_argument, rcol_compare_utf8(coll, null, 1, null, 0, &order));
    try testing.expectEqual(@as(i32, 77), order);
    try testing.expectEqual(Status.invalid_argument, rcol_compare_utf8(coll, null, 0, null, 0, null));

    var needed: usize = 77;
    try testing.expectEqual(Status.invalid_argument, rcol_sort_key_utf8(coll, null, 1, null, 0, &needed));
    try testing.expectEqual(@as(usize, 0), needed);
    try testing.expectEqual(Status.invalid_argument, rcol_sort_key_utf8(coll, null, 0, null, 1, &needed));
    try testing.expectEqual(Status.invalid_argument, rcol_sort_key_utf8(coll, null, 0, null, 0, null));

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var failing_coll = Collator{ .options = 0, .allocator = failing.allocator() };
    try testing.expectEqual(Status.out_of_memory, rcol_sort_key_utf8(&failing_coll, null, 0, null, 0, &needed));
    try testing.expectEqual(@as(usize, 0), needed);

    const long = try testing.allocator.alloc(u8, 9000);
    defer testing.allocator.free(long);
    @memset(long, 'a');
    try testing.expectEqual(Status.out_of_memory, rcol_compare_utf8(&failing_coll, long.ptr, long.len, long.ptr, long.len, &order));
    try testing.expectEqual(@as(i32, 77), order);
}

test "ffi: status names are stable static strings" {
    try testing.expectEqualStrings("ok", std.mem.span(rcol_status_name(@intFromEnum(Status.ok))));
    try testing.expectEqualStrings("out of memory", std.mem.span(rcol_status_name(@intFromEnum(Status.out_of_memory))));
    try testing.expectEqualStrings("unknown status", std.mem.span(rcol_status_name(99)));
}
