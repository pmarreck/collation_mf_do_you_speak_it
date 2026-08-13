const std = @import("std");

pub fn build(b: *std.Build) void {
    var target_query = b.standardTargetOptionsQueryOnly(.{});
    // For a NATIVE Linux build, force an explicit static-musl target. Zig links
    // musl statically when the abi is explicit (non-native), yielding a fully
    // static, loader-free binary that runs on any Linux — including NixOS,
    // whose store lacks the FHS `/lib/ld-*` loader paths a dynamic binary
    // needs. An explicit `-Dtarget=` (cross-compilation) is respected untouched.
    if (target_query.os_tag == null and @import("builtin").os.tag == .linux) {
        target_query.abi = .musl;
    }
    const target = b.resolveTargetQuery(target_query);
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    // ─── Core library module (pure Zig, no I/O) ──────────────────────────
    // Exposed for downstream Zig consumers who want to skip the C ABI.
    _ = b.addModule("romantic_collation", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ─── Static library with C ABI (the FFI boundary) ────────────────────
    const lib = b.addLibrary(.{
        .name = "romantic_collation",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    b.installArtifact(lib);

    // ─── C CLI executable (dogfoods the FFI) ─────────────────────────────
    // In Zig 0.16, linkLibrary / addCSourceFile / addIncludePath all live on
    // the *Build.Module rather than the *Step.Compile. Configure the module
    // before passing it to addExecutable.
    const cli_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cli_mod.addCSourceFile(.{
        .file = b.path("cli/main.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic" },
    });
    cli_mod.addIncludePath(b.path("include"));
    cli_mod.linkLibrary(lib);
    const cli = b.addExecutable(.{
        .name = "collate",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    // ─── Run step ────────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(cli);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the collate CLI").dependOn(&run_cmd.step);

    // ─── Unit tests ──────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const run_tests = b.addRunArtifact(b.addTest(.{
        .root_module = test_mod,
    }));
    b.step("test", "Run unit tests").dependOn(&run_tests.step);

    // C-side unit tests exercise CLI adapter failures that the successful Zig
    // FFI cannot produce on demand. The test includes cli/main.c so it reaches
    // static adapter seams while the production executable remains unchanged.
    const c_test_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_test_mod.addCSourceFile(.{
        .file = b.path("tests/unit/cli_key_failure.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic" },
    });
    c_test_mod.addIncludePath(b.path("include"));
    c_test_mod.linkLibrary(lib);
    const c_tests = b.addExecutable(.{
        .name = "cli-key-failure-test",
        .root_module = c_test_mod,
    });
    const run_c_tests = b.addRunArtifact(c_tests);
    b.step("c-test", "Run C CLI adapter unit tests").dependOn(&run_c_tests.step);

    // ─── Property fuzzer ─────────────────────────────────────────────────
    // Checks the ORDERING laws (key-order == compare-order, reflexivity,
    // antisymmetry, transitivity, C-safe keys) rather than merely "does it
    // crash" — an ordering bug never crashes. Driven by ./fuzz.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const fuzz_exe = b.addExecutable(.{
        .name = "collation-fuzz",
        .root_module = fuzz_mod,
    });
    b.installArtifact(fuzz_exe);
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    run_fuzz.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_fuzz.addArgs(args);
    b.step("fuzz", "Run the collation property fuzzer").dependOn(&run_fuzz.step);
}
