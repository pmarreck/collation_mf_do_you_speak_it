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
    _ = b.addModule("collation_mf_do_you_speak_it", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ─── Static library with C ABI (the FFI boundary) ────────────────────
    const lib = b.addLibrary(.{
        .name = "collation_mf_do_you_speak_it",
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
}
