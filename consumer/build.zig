// SPDX-License-Identifier: MIT
// See ../FORK-LICENSE.md for what that identifier covers.
//
//! Consumer build graph; it tests consumption through the published `lua` module and its artifact.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Pass linkage through so this example tests the selected library artifact.
    const linkage = b.option(
        std.lang.LinkMode,
        "linkage",
        "Which delivery of liblua to check. Forwarded to the dependency; it " ++
            "decides the artifact, never anything in this package.",
    ) orelse .static;
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Check the dependency's runtime-loading dispatch instead of a linked " ++
            "one. Forwarded to the dependency. A program built this way has to " ++
            "name a provider with an explicit load() before any native call, " ++
            "which is src/main.zig's business and not this file's.",
    ) orelse false;

    const dep = b.dependency("lua", .{
        .target = target,
        .optimize = optimize,
        .linkage = linkage,
        .runtime = runtime_loaded,
    });

    // System mode comes from `-fsys` / `-fno-sys`, not the `-D` option map.
    // The dependency shares the build graph, so its `systemIntegrationOption` sees the same setting.

    // The library module declares libc linkage; do not mask a missing declaration here.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("lua", dep.module("lua"));

    const exe = b.addExecutable(.{
        .name = "lua-consumer",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.has_side_effects = true;
    // Forward runtime-loader arguments to the consumer executable.
    run_exe.addPassthruArgs();
    const run_step = b.step("run", "Build and run the consumer program");
    run_step.dependOn(&run_exe.step);
}
