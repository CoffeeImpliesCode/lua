// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.
const std = @import("std");

/// Loader graph with builders for runtime and linked modes.
/// Create one core module per build; duplicates make `LoadSource` and `LoadError` incompatible types.
const graph = @import("runtime/graph.zig");

const manifest = @import("build.zig.zon");

/// Parsed manifest version; malformed values fail configuration.
const manifest_version = std.SemanticVersion.parse(manifest.version) catch
    @panic("build.zig.zon: .version is not a semantic version");

/// Package, dependency, module, and C artifact name.
const lib_name = "lua";

const facade_source = "zig/root.zig";

/// Aggregate header passed to translate-c.
const translate_header = "zig/translate.h";

const test_source = "tests.zig";

const example_source = "smoke.zig";

/// Upstream source directory; internal includes resolve from here.
const source_dir = "src";

/// Upstream release version; the manifest check prevents version drift.
const upstream_version: std.SemanticVersion = .{ .major = 5, .minor = 5, .patch = 1 };

/// Shared-library ABI number; major 55 follows upstream's `lua55.dll` name.
const abi_version: std.SemanticVersion = .{ .major = 55, .minor = 5, .patch = 1 };

/// Upstream CORE_O units in Makefile order (`src/Makefile:36`).
const core_sources = [_][]const u8{
    "src/lapi.c",
    "src/lcode.c",
    "src/lctype.c",
    "src/ldebug.c",
    "src/ldo.c",
    "src/ldump.c",
    "src/lfunc.c",
    "src/lgc.c",
    "src/llex.c",
    "src/lmem.c",
    "src/lobject.c",
    "src/lopcodes.c",
    "src/lparser.c",
    "src/lstate.c",
    "src/lstring.c",
    "src/ltable.c",
    "src/ltm.c",
    "src/lundump.c",
    "src/lvm.c",
    "src/lzio.c",
};

/// Upstream LIB_O units, including all ten standard-library openers (`src/Makefile:37`).
const lib_sources = [_][]const u8{
    "src/lauxlib.c",
    "src/lbaselib.c",
    "src/lcorolib.c",
    "src/ldblib.c",
    "src/liolib.c",
    "src/lmathlib.c",
    "src/loadlib.c",
    "src/loslib.c",
    "src/lstrlib.c",
    "src/ltablib.c",
    "src/lutf8lib.c",
    "src/linit.c",
};

const Program = struct {
    name: []const u8,
    source: []const u8,
};

const interpreter: Program = .{ .name = "lua", .source = "src/lua.c" };

/// Upstream requires `luac` to link statically (`doc/readme.html`, `src/Makefile:132-135`).
const compiler: Program = .{ .name = "luac", .source = "src/luac.c" };

/// Upstream's five installed headers; `lua.hpp` is installed because it is C++.
const public_headers = [_][]const u8{
    "src/lua.h",
    "src/luaconf.h",
    "src/lauxlib.h",
    "src/lualib.h",
    "src/lua.hpp",
};

/// Upstream manual pages installed under `share/man/man1`.
const man_pages = [_][]const u8{
    "doc/lua.1",
    "doc/luac.1",
};

/// License and provenance files installed under `share/licenses/lua`.
const licence_records = [_][]const u8{
    "src/lua.h",
    "doc/readme.html",
    "README",
    "NOTICE.md",
    "FORK-LICENSE.md",
    "UPSTREAM.md",
    "UPSTREAM.sha256",
    "FORK-NOTES.md",
    "CHANGELOG.md",
};

/// Upstream's default C dialect, pinned for every unit (`src/Makefile:9`).
const c_flags = [_][]const u8{"-std=gnu99"};

const Library = enum {
    bundled,
    system,
};

/// Compile-check targets; refused targets are listed separately.
const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
};

/// Targets rejected by `refusalFor` before configuration.
const refused_check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

/// Names matrix artifacts by target to avoid collisions.
fn programName(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    base: []const u8,
    public: bool,
) []const u8 {
    if (public) return base;
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    return b.fmt("{s}-{s}-{s}", .{ base, lib_name, triple });
}

/// The two upstream executables for one target.
const Programs = struct {
    lua: *std.Build.Step.Compile,
    luac: *std.Build.Step.Compile,
};

/// Target-derived macros and system-library requirements.
const Platform = struct {
    /// LUA_USE macros for this target.
    macros: []const [2][]const u8,
    /// Whether Lua can load C modules with dlopen.
    dlopen: bool,
    /// Whether dlopen needs a separate library.
    separate_dl: bool,
    /// Whether libm needs a separate library.
    separate_m: bool,
    /// Whether the target supports the Windows DLL declaration split.
    dll: bool,

    fn forTarget(target: std.Build.ResolvedTarget) Platform {
        const os_tag = target.result.os.tag;
        if (os_tag == .windows) {
            // Windows derives LUA_USE_WINDOWS from _WIN32; define no macro (`src/luaconf.h:50-52`).
            return .{
                .macros = &.{},
                .dlopen = false,
                .separate_dl = false,
                .separate_m = false,
                .dll = true,
            };
        }
        if (os_tag == .wasi) {
            // Preserve upstream's no-POSIX/no-dlopen fallback; addGraph refuses WASI before this branch.
            return .{
                .macros = &.{},
                .dlopen = false,
                .separate_dl = false,
                .separate_m = true,
                .dll = false,
            };
        }
        if (os_tag == .maccatalyst) {
            // LUA_USE_IOS selects upstream's Catalyst os.execute fallback (`src/loslib.c:133-140`).
            // It expands to POSIX/dlopen without enabling readline (`src/luaconf.h:86-89`).
            return .{
                .macros = &.{.{ "LUA_USE_IOS", "1" }},
                .dlopen = true,
                // Darwin provides dlopen through libc (`src/luaconf.h:81`).
                .separate_dl = false,
                .separate_m = true,
                .dll = false,
            };
        }
        if (os_tag.isDarwin()) {
            // Avoid LUA_USE_MACOSX because it enables readline (`src/luaconf.h:79-83`).
            return .{
                .macros = &.{
                    .{ "LUA_USE_POSIX", "1" },
                    .{ "LUA_USE_DLOPEN", "1" },
                },
                .dlopen = true,
                .separate_dl = false,
                .separate_m = true,
                .dll = false,
            };
        }
        if (os_tag == .linux) {
            // Upstream's LUA_USE_LINUX expands to POSIX, dlopen, and runtime readline (`src/Makefile:123-124`, `src/luaconf.h:70-76`).
            return .{
                .macros = &.{.{ "LUA_USE_LINUX", "1" }},
                .dlopen = true,
                .separate_dl = true,
                .separate_m = true,
                .dll = false,
            };
        }
        // Match upstream's POSIX/Solaris recipe and keep readline as a runtime lookup (`src/Makefile:138-142`).
        return .{
            .macros = &.{
                .{ "LUA_USE_POSIX", "1" },
                .{ "LUA_USE_DLOPEN", "1" },
                .{ "LUA_READLINELIB", "libreadline.so" },
            },
            .dlopen = true,
            .separate_dl = true,
            .separate_m = true,
            .dll = false,
        };
    }

    /// Labels the resolved macro set for configure output.
    fn kind(platform: Platform) []const u8 {
        if (platform.macros.len == 0) return "no platform macro; upstream's own default path";
        if (std.mem.eql(u8, platform.macros[0][0], "LUA_USE_LINUX")) return "upstream's LUA_USE_LINUX expansion";
        if (std.mem.eql(u8, platform.macros[0][0], "LUA_USE_IOS")) return "upstream's LUA_USE_IOS expansion";
        if (platform.macros.len == 2) return "LUA_USE_POSIX, LUA_USE_DLOPEN";
        return "LUA_USE_POSIX, LUA_USE_DLOPEN, LUA_READLINELIB";
    }
};

/// C preprocessing routes used before translation.
const AggregateRoute = enum {
    /// Aro preprocesses and parses the aggregate header.
    aro,
    /// Target C preprocessing expands the header before Aro parses it.
    preprocessed,
};

/// Use target preprocessing on NetBSD and OpenBSD headers Aro cannot parse.
fn aggregateRoute(target: std.Build.ResolvedTarget) AggregateRoute {
    return switch (target.result.os.tag) {
        .netbsd, .openbsd => .preprocessed,
        else => .aro,
    };
}

/// Preprocesses the aggregate header for NetBSD and OpenBSD.
/// Reuse target flags; `-dD` preserves macros and `-MD` tracks included headers.
fn preprocessedAggregate(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    include_dir: ?std.Build.LazyPath,
    macros: []const [2][]const u8,
    dll_macro: bool,
) std.Build.LazyPath {
    const run = b.addSystemCommand(&[_][]const u8{ b.graph.zig_exe, "cc", "-E", "-dD" });
    run.setName("preprocess lua translate.h");
    if (!target.query.isNative()) {
        const triple = target.query.zigTriple(b.allocator) catch @panic("lua: unspellable target");
        run.addArg("-target");
        run.addArg(triple);
    }
    run.addArgs(&c_flags);
    if (include_dir) |dir| run.addDirectoryArg2(dir, .{ .prefix = "-I" });
    for (macros) |macro| run.addArg(b.fmt("-D{s}={s}", .{ macro[0], macro[1] }));
    if (dll_macro) run.addArg("-DLUA_BUILD_AS_DLL=1");
    run.addArg("-o");
    const preprocessed = run.addOutputFileArg2("lua-translate.c", .{});
    run.addArg("-MD");
    _ = run.addDepFileOutputArg2("lua-translate.d", .{ .prefix = "-MF" });
    run.addFileArg2(b.path(translate_header), .{});
    return preprocessed;
}

/// Modules and platform settings for one target.
const Graph = struct {
    /// The compiled C library, or null in system mode.
    c_lib: ?*std.Build.Step.Compile,
    /// Facade module bound to the translated headers.
    module: *std.Build.Module,
    /// Target platform configuration.
    platform: Platform,
};

/// Matrix artifact names include the target triple.
fn artifactName(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    public: bool,
) []const u8 {
    if (public) return lib_name;
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    return b.fmt("{s}-{s}", .{ lib_name, triple });
}

/// Builds one target's library, translation, and facade.
fn addGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    library: Library,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
    public: bool,
) Graph {
    // Refuse unsupported targets before configuration so direct builds and checks share one boundary.
    if (refusalFor(target.result.os.tag) != null) refuseTarget(b, target);

    const platform = Platform.forTarget(target);
    const c_lib: ?*std.Build.Step.Compile = if (library == .bundled)
        add_c_library(b, target, optimize, linkage, platform, artifactName(b, target, public))
    else
        null;

    // Resolve effective linkage for consistent translation and library settings.
    const delivered = deliveredLinkage(target, linkage);

    // Resolve target macros and include paths once for both translation routes.
    const no_macros: []const [2][]const u8 = &.{};
    const translate_macros = if (library == .bundled) platform.macros else no_macros;
    const translate_include: ?std.Build.LazyPath =
        if (library == .bundled) b.path(source_dir) else null;
    const translate_dll = library == .bundled and delivered == .dynamic and platform.dll;

    const translate = b.addTranslateC(.{
        .root_source_file = switch (aggregateRoute(target)) {
            .aro => b.path(translate_header),
            .preprocessed => preprocessedAggregate(
                b,
                target,
                translate_include,
                translate_macros,
                translate_dll,
            ),
        },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (translate_include) |dir| {
        // Bundled mode uses local headers; system mode resolves installed headers.
        translate.addIncludePath(dir);
    }
    // Keep translated macros aligned with C compilation to preserve ABI and constants.
    for (translate_macros) |macro| translate.defineCMacro(macro[0], macro[1]);
    if (translate_dll) {
        // Translate with the Windows DLL import macro (`src/luaconf.h:305-311`).
        translate.defineCMacro("LUA_BUILD_AS_DLL", "1");
    }

    // System mode resolves the installed library and headers together.
    if (library == .system) {
        translate.linkSystemLibrary(lib_name, .{ .preferred_link_mode = linkage });
    }

    const module = if (public)
        b.addModule(lib_name, .{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        })
    else
        b.createModule(.{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
    // Runtime dispatch reuses this translation so the facade and dispatch share C declarations.
    // Create one core module per build so `LoadSource` and `LoadError` retain type identity.
    if (runtime_loaded) {
        // Do not link the archive; calls must resolve through the selected provider.
        module.addImport("c", graph.createModule(b, translate, target, optimize));
    } else {
        // Import, do not register, the translated module; C symbols require facade linkage.
        module.addImport("c", translate.createModule());
        module.addImport("rt", graph.createCoreModule(b, target, optimize));
        // System-mode linkage is already carried by the translated module.
        if (c_lib) |lib| module.linkLibrary(lib);
    }

    // Bundled C consumers use the same local headers as the library.
    if (library == .bundled) module.addIncludePath(b.path(source_dir));

    return .{ .c_lib = c_lib, .module = module, .platform = platform };
}

/// Compiles upstream core and library units for one target.
/// Shared delivery adds versioning, PIC, exports, and platform DLL settings.
fn add_c_library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    requested: std.lang.LinkMode,
    platform: Platform,
    name: []const u8,
) *std.Build.Step.Compile {
    const linkage = deliveredLinkage(target, requested);
    const c_lib = b.addLibrary(.{
        .name = name,
        .linkage = linkage,
        // Static archives have no version or SONAME.
        .version = if (linkage == .dynamic) abi_version else null,
        .win32_module_definition = if (linkage == .dynamic and target.result.ofmt == .coff)
            b.addWriteFiles().add("lua.def", "EXPORTS\nlua_ident DATA\n")
        else
            null,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .pic = if (linkage == .dynamic) true else null,
        }),
    });
    const c_mod = c_lib.root_module;

    // Upstream sources include their neighboring headers by name.
    c_mod.addIncludePath(b.path(source_dir));

    // Derive platform macros from the target, not the build host.
    for (platform.macros) |macro| {
        c_mod.addCMacro(macro[0], macro[1]);
    }

    // Define upstream's export macros only for Windows DLL builds (`src/luaconf.h:305-311`).
    const windows_dll = platform.dll and linkage == .dynamic;
    if (windows_dll) {
        c_mod.addCMacro("LUA_BUILD_AS_DLL", "1");
        c_mod.addCMacro("LUA_CORE", "1");
        c_mod.addCMacro("LUA_LIB", "1");
    }

    // The WASI sysroot requires emulated signal support; link its supplied implementation.
    // Keep this dependency on the library so dependents inherit it.
    if (target.result.os.tag == .wasi) {
        c_mod.addCMacro("_WASI_EMULATED_SIGNAL", "1");
        c_mod.linkSystemLibrary("wasi-emulated-signal", .{});
    }

    for (core_sources) |source| {
        c_mod.addCSourceFile(.{
            .file = b.path(source),
            .flags = &c_flags,
        });
    }
    for (lib_sources) |source| {
        c_mod.addCSourceFile(.{
            .file = b.path(source),
            .flags = &c_flags,
        });
    }

    // Follow upstream's -lm and -ldl requirements for this target (`src/Makefile:12`).
    if (platform.separate_m) c_mod.linkSystemLibrary("m", .{});
    if (linkage == .dynamic and platform.separate_dl and platform.dlopen) {
        c_mod.linkSystemLibrary("dl", .{});
    }

    if (linkage == .dynamic) setVersionScript(b, c_lib, target);

    // Install upstream's public header set.
    for (public_headers) |header| {
        c_lib.installHeader(b.path(header), std.fs.path.basename(header));
    }

    return c_lib;
}

/// Writes an ELF version script that exports Lua's public namespaces.
/// Mach-O has no equivalent here and exposes internal symbols.
fn setVersionScript(
    b: *std.Build,
    c_lib: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    if (target.result.ofmt != .elf) return;

    const files = b.addWriteFiles();
    c_lib.setVersionScript(files.add("lua.map",
        \\LUA_5_5 {
        \\  global:
        \\    lua_*;
        \\    luaL_*;
        \\    luaopen_*;
        \\  local:
        \\    *;
        \\};
        \\
    ));
}

/// Builds both upstream programs for one target.
/// The interpreter follows selected linkage; `luac` always links statically.
fn add_programs(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    linkage: std.lang.LinkMode,
    platform: Platform,
    c_lib: *std.Build.Step.Compile,
    public: bool,
) Programs {
    const delivered = deliveredLinkage(target, linkage);

    // Build a second static archive for `luac` when delivery is dynamic.
    const luac_lib = if (delivered == .static)
        c_lib
    else
        add_c_library(
            b,
            target,
            optimize,
            .static,
            platform,
            programName(b, target, b.fmt("{s}-lib", .{compiler.name}), public),
        );

    return .{
        .lua = add_program(
            b,
            target,
            optimize,
            delivered,
            platform,
            c_lib,
            interpreter,
            programName(b, target, interpreter.name, public),
            true,
        ),
        .luac = add_program(
            b,
            target,
            optimize,
            .static,
            platform,
            luac_lib,
            compiler,
            programName(b, target, compiler.name, public),
            false,
        ),
    };
}

/// One program: its `main`, its platform macros and the library it links.
fn add_program(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    linkage: std.lang.LinkMode,
    platform: Platform,
    c_lib: *std.Build.Step.Compile,
    program: Program,
    name: []const u8,
    export_dynamic: bool,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(b.path(source_dir));
    for (platform.macros) |macro| mod.addCMacro(macro[0], macro[1]);
    // Windows DLL consumers need `LUA_BUILD_AS_DLL` (`src/luaconf.h:305-311`).
    if (platform.dll and linkage == .dynamic) {
        mod.addCMacro("LUA_BUILD_AS_DLL", "1");
    }

    // Match the library's WASI signal-emulation macro on each program.
    if (target.result.os.tag == .wasi) {
        mod.addCMacro("_WASI_EMULATED_SIGNAL", "1");
    }

    mod.addCSourceFile(.{
        .file = b.path(program.source),
        .flags = &c_flags,
    });
    if (platform.separate_m) mod.linkSystemLibrary("m", .{});
    if (platform.dlopen and platform.separate_dl) mod.linkSystemLibrary("dl", .{});
    mod.linkLibrary(c_lib);
    // Resolve installed shared libraries relative to the program.
    if (linkage == .dynamic) {
        if (installedRPath(target)) |rpath| mod.addRPathSpecial(rpath);
    }

    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    // Export static ELF interpreter symbols for C modules (`src/Makefile:123-124`).
    if (export_dynamic and
        linkage == .static and
        target.result.ofmt == .elf)
    {
        exe.rdynamic = true;
    }
    return exe;
}

/// Returns the relative runtime path for installed shared libraries, or null when unsupported.
fn installedRPath(target: std.Build.ResolvedTarget) ?[]const u8 {
    return switch (target.result.ofmt) {
        .elf => "$ORIGIN/../lib",
        .macho => "@loader_path/../lib",
        else => null,
    };
}

/// Compiles the facade, tests, and example for one target; also builds bundled programs.
fn add_target_check(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.lang.Optimize,
    library: Library,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
) void {
    const cross_target = b.resolveTargetQuery(query);
    // Include the target triple in matrix artifact names.
    const triple = cross_target.result.zigTriple(b.allocator) catch @panic("unspellable target");

    const cross = addGraph(b, cross_target, optimize, library, linkage, runtime_loaded, false);

    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, cross.module);
    step.dependOn(&b.addTest(.{
        .name = b.fmt("lua-tests-{s}", .{triple}),
        .root_module = test_mod,
    }).step);

    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, cross.module);
    step.dependOn(&b.addExecutable(.{
        .name = b.fmt("lua-smoke-{s}", .{triple}),
        .root_module = example_mod,
    }).step);

    // System mode has no local library for the programs to link.
    if (cross.c_lib) |c_lib| {
        const programs = add_programs(
            b,
            cross_target,
            optimize,
            linkage,
            cross.platform,
            c_lib,
            false,
        );
        step.dependOn(&programs.lua.step);
        step.dependOn(&programs.luac.step);
    }
}

/// Builds `consumer/` with the selected target and build options.
/// Runs the nested consumer only for native targets; otherwise installs it.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    library: Library,
    linkage: std.lang.LinkMode,
    runtime_loaded: bool,
) *std.Build.Step.Run {
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    // Target triples omit CPU features; forward the resolved CPU separately.
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // Use this build's Zig executable for the nested package build.
    const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(if (hostCanExecute(b, target)) "run" else "install");
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // Forward delivery and runtime options so the consumer uses this configuration.
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    // Pass explicit runtime state instead of relying on the dependency's default.
    run.addArg(b.fmt("-Druntime={s}", .{if (runtime_loaded) "true" else "false"}));
    // Forward resolved system mode; -fsys/-fno-sys are runner flags, not -D options.
    run.addArg(if (library == .system) b.fmt("-fsys={s}", .{lib_name}) else b.fmt("-fno-sys={s}", .{lib_name}));
    run.addThirdPartyEnabledArgDarling(.{ .enabled = "-fdarling" });
    run.addThirdPartyEnabledArgQemu(.{ .enabled = "-fqemu" });
    run.addThirdPartyEnabledArgRosetta(.{ .enabled = "-frosetta" });
    run.addThirdPartyEnabledArgWasmtime(.{ .enabled = "-fwasmtime" });
    run.addThirdPartyEnabledArgWine(.{ .enabled = "-fwine" });
    // Match the parent build's job count and summary in the nested graph.
    run.addArg("-j8");
    run.addArg("--summary");
    run.addArg("all");
    // Forward caller arguments after -- to the consumer executable.
    run.addArg("--");
    run.addPassthruArgs();
    run.has_side_effects = true;
    return run;
}

/// Run the nested consumer only for native targets; 0.17 resolves executor toggles at make time.
fn hostCanExecute(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const host = &b.graph.host.result;
    const candidate = &target.result;
    const options: std.zig.system.GetExternalExecutorOptions = .{
        .host_cpu_arch = host.cpu.arch,
        .host_os_tag = host.os.tag,
        .link_mode = .dynamic,
        .link_libc = true,
    };
    return switch (std.zig.system.getExternalExecutor(b.graph.io, candidate, options)) {
        .native => true,
        .rosetta, .qemu, .wine, .wasmtime, .darling, .bad_dl, .bad_os_or_cpu => false,
    };
}

/// Writes relocatable `lua.pc` metadata for the selected linkage and platform.
/// Its `-lm`/`-ldl` flags follow upstream's link requirements.
fn add_pkg_config(b: *std.Build, platform: Platform, linkage: std.lang.LinkMode) void {
    const files = b.addWriteFiles();
    // Bind the generated file's install step; an unbound step installs nothing.
    const install_pc = b.addInstallFileWithDir(
        files.add("lua.pc", b.fmt(
            \\# lua.pc for the Lua 5.5.1 SDK.
            \\#
            \\# Lua's release tarball ships no pkg-config file: Makefile:96-101 is a
            \\# `pc` target that only echoes the values below, and src/Makefile has no
            \\# such target. Every field here is therefore this fork's, and build.zig's
            \\# add_pkg_config names the upstream line each one comes from. `prefix`
            \\# is pcfiledir-relative so the installed file is correct wherever
            \\# --prefix put it.
            \\prefix=${{pcfiledir}}/../..
            \\exec_prefix=${{prefix}}
            \\libdir=${{prefix}}/lib
            \\includedir=${{prefix}}/include
            \\
            \\Name: lua
            \\Description: Lua 5.5.1, the extensible scripting language
            \\Version: {f}
            \\
            \\Requires:
            \\Libs: -L"${{libdir}}" -llua
            \\Libs.private:{s}{s}
            \\Cflags: -I"${{includedir}}"{s}
            \\
        , .{
            upstream_version,
            // Upstream always links libm (`src/Makefile:12`).
            " -lm",
            // Link libdl only where dlopen uses a separate library.
            if (platform.dlopen and platform.separate_dl) " -ldl" else "",
            // Add the import macro only for Windows shared builds.
            if (linkage == .dynamic and platform.dll) " -DLUA_BUILD_AS_DLL" else "",
        })),
        .prefix,
        "lib/pkgconfig/lua.pc",
    );
    b.getInstallStep().dependOn(&install_pc.step);
}

/// Installs license and provenance records under `share/licenses/lua/`.
fn install_licence_records(b: *std.Build) void {
    for (licence_records) |record| {
        const install_record = b.addInstallFileWithDir(
            b.path(record),
            .prefix,
            b.fmt("share/licenses/lua/{s}", .{std.fs.path.basename(record)}),
        );
        b.getInstallStep().dependOn(&install_record.step);
    }
}

/// Installs upstream manual pages under `share/man/man1/`.
fn install_man_pages(b: *std.Build) void {
    for (man_pages) |page| {
        const install_page = b.addInstallFileWithDir(
            b.path(page),
            .prefix,
            b.fmt("share/man/man1/{s}", .{std.fs.path.basename(page)}),
        );
        b.getInstallStep().dependOn(&install_page.step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const system_default = b.option(
        bool,
        "system",
        "Link an installed liblua instead of compiling src/, and translate the " ++
            "installed headers instead of the bundled ones. This supplies the " ++
            "default of systemIntegrationOption(\"lua\"); a build runner that " ++
            "decides the mode itself (-fsys=lua) overrides it.",
    ) orelse false;

    const use_system = b.systemIntegrationOption(lib_name, .{ .default = system_default });
    const library: Library = if (use_system) .system else .bundled;

    const linkage_option = b.option(
        std.lang.LinkMode,
        "linkage",
        "Deliver the native library as a static archive (the default, and what " ++
            "upstream's own Makefile builds) or as a real shared object with " ++
            "upstream's Lua-5.5 ABI name. This selects the delivery and never " ++
            "the dispatch: the same 32 C units are compiled either way. In " ++
            "system mode this graph builds no artifact at all, so there the " ++
            "option names the kind of installed library to bind to instead, and " ++
            "it defaults to dynamic.",
    );

    // Bundled mode defaults to static; system mode defaults to dynamic.
    const linkage: std.lang.LinkMode = linkage_option orelse
        (if (library == .system) .dynamic else .static);

    // Runtime dispatch is independent of delivered linkage.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native entry points at run time instead of linking them. " ++
            "The facade keeps the same translated headers and the same public " ++
            "types; each selected native function becomes a dispatch through " ++
            "one process-lifetime table that an explicit load(source) fills, " ++
            "and the module links no archive. Independent of -Dlinkage, which " ++
            "still decides which artifact this build delivers and installs. " ++
            "Default off, and a linked build is unchanged in every respect.",
    ) orelse false;

    // Keep manifest, upstream-header, pkg-config, and artifact versions aligned.
    if (manifest_version.order(upstream_version) != .eq) {
        @panic("build.zig.zon .version no longer matches the version read out " ++
            "of src/lua.h; see UPSTREAM.md");
    }

    // Check that supported and refused target lists match `refusalFor`.
    checkMatrixPartition(b);

    const published = addGraph(b, target, optimize, library, linkage, runtime_loaded, true);

    // Do not install local artifacts or build programs in system mode.
    if (published.c_lib) |c_lib| {
        b.installArtifact(c_lib);
        add_pkg_config(b, published.platform, deliveredLinkage(target, linkage));
        install_licence_records(b);
        install_man_pages(b);

        // The interpreter follows delivery; `luac` always links statically.
        const programs = add_programs(
            b,
            target,
            optimize,
            linkage,
            published.platform,
            c_lib,
            true,
        );
        b.installArtifact(programs.lua);
        b.installArtifact(programs.luac);
    }

    // Build the example but do not install it.
    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, published.module);
    const example = b.addExecutable(.{
        .name = "lua-smoke",
        .root_module = example_mod,
    });
    b.getInstallStep().dependOn(&example.step);

    // Keep the smoke step independent of installation.
    const run_example = b.addRunArtifact(example);
    run_example.has_side_effects = true;
    run_example.addPassthruArgs();
    b.step("smoke", "Run the deterministic example program").dependOn(&run_example.step);

    // Run the test root; cross-test selects an executor for foreign targets.
    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, published.module);
    const unit_tests = b.addTest(.{
        .name = "lua-tests",
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    run_tests.has_side_effects = true;
    b.step("test", "Run the behavioural tests").dependOn(&run_tests.step);

    // Pass the resolved library mode to the nested consumer build.
    b.step("consumer", "Build or run the consumer/ package for the selected target")
        .dependOn(&runConsumer(b, target, optimize, library, deliveredLinkage(target, linkage), runtime_loaded).step);

    // Compile-only matrix for the public entry points.
    const check_step = b.step(
        "check",
        "Compile the native library, the facade, the tests, the example and " ++
            "both programs for the five buildable check targets without running " ++
            "any of them",
    );
    if (!target.query.isNative()) {
        add_target_check(b, check_step, target.query, optimize, library, linkage, runtime_loaded);
    } else {
        for (check_targets[0..]) |query| {
            add_target_check(b, check_step, query, optimize, library, linkage, runtime_loaded);
        }
    }

    if (published.c_lib != null) {
        std.debug.print("lua: {d} core + {d} library units, {s}, C99 (gnu99), 64-bit lua_Integer and double lua_Number\n", .{
            core_sources.len,
            lib_sources.len,
            published.platform.kind(),
        });
        std.debug.print("lua: {s}\n", .{switch (deliveredLinkage(target, linkage)) {
            .static => "static archive liblua.a (default, and what upstream builds)",
            .dynamic => b.fmt("shared object liblua.so.{d}.{d}.{d}, soname liblua.so.{d}", .{
                abi_version.major,
                abi_version.minor,
                abi_version.patch,
                abi_version.major,
            }),
        }});
        if (runtime_loaded) {
            std.debug.print(
                "lua: runtime-loaded dispatch (-Druntime=true); the facade module " ++
                    "links no archive and a provider is named by an explicit " ++
                    "load(source)\n",
                .{},
            );
        }
        if (deliveredLinkage(target, linkage) == .dynamic and
            target.result.ofmt != .elf)
        {
            // Darwin shared objects export internals because no version script is used.
            std.debug.print(
                "lua: {s} has no version-script mechanism here, so the shared " ++
                    "object exports Lua's internal symbols as well as its API\n",
                .{@tagName(target.result.ofmt)},
            );
        }
    } else {
        std.debug.print("lua: system liblua (-llua) and the installed headers; this package installs nothing and builds neither program\n", .{});
        if (runtime_loaded) {
            std.debug.print(
                "lua: runtime-loaded dispatch (-Druntime=true) over the installed " ++
                    "provider named by an explicit load(source)\n",
                .{},
            );
        }
    }
}

/// Returns whether the target OS can load a shared object.
fn targetHasDynamicLinker(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows or std.Target.DynamicLinker.kind(target.result.os.tag) != .none;
}

/// Returns the requested linkage or rejects dynamic linkage without a target loader.
/// Never substitute a static archive for a requested shared object.
fn deliveredLinkage(
    target: std.Build.ResolvedTarget,
    requested: std.lang.LinkMode,
) std.lang.LinkMode {
    if (requested == .dynamic and !targetHasDynamicLinker(target)) {
        // Format the target tag at runtime.
        std.debug.panic(
            "lua: -Dlinkage=dynamic was asked for {s}, which has no dynamic " ++
                "linker: std.Target.DynamicLinker.kind is .none for it, so it cannot " ++
                "carry a shared object at all. This build does not substitute a static " ++
                "archive for a requested shared object. Build that target with the " ++
                "default -Dlinkage=static, which is also what upstream's src/Makefile " ++
                "produces there and what its own src/loadlib.c and src/liolib.c " ++
                "branches expect.",
            .{@tagName(target.result.os.tag)},
        );
    }
    return requested;
}

/// Summary and detailed reason a target is refused.
const Refusal = struct {
    summary: []const u8,
    detail: []const u8,
};

fn refusalFor(os_tag: std.Target.Os.Tag) ?Refusal {
    if (os_tag == .wasi) {
        return .{
            .summary = "Lua has no buildable configuration for this target: src/loslib.c's tmpnam configuration has no arm this toolchain's WASI libc can compile.",
            .detail =
            \\src/loslib.c:97-130 is upstream's own configuration block for
            \\'tmpnam', and it has exactly two arms. LUA_USE_POSIX selects
            \\mkstemp over <unistd.h> (:105-119); without it the ISO C arm is
            \\selected, which is tmpnam (:121-127). os.tmpname at :172-180 reads
            \\both unconditionally, so whichever arm is selected has to work.
            \\
            \\The outer guard at :103 is `#if !defined(lua_tmpnam)`, so the block
            \\is skipped when that macro is already defined. That is upstream's
            \\documented extension point, and it is not a switch: it is the
            \\(buffer, error) statement itself, the one :115-119 and :125 spell
            \\out. Setting it means this package writes the C that creates the
            \\temporary file, which is a substitute rather than a configuration,
            \\so it is not done here. LUA_TMPNAMBUFSIZE (:109, :124) and
            \\LUA_TMPNAMTEMPLATE (:111-113) only size and seed those two arms,
            \\and src/luaconf.h, src/Makefile and doc/readme.html name no tmpnam
            \\macro at all - that block is the whole of upstream's configuration
            \\for it, and src/Makefile has no wasm target to copy.
            \\
            \\Zig 0.17.0's WASI libc has neither arm. Both names are removed
            \\rather than deprecated, each behind `#ifdef
            \\__wasilibc_unmodified_upstream /* WASI has no temp directories */`:
            \\lib/libc/include/wasm-wasi-musl/stdio.h:148-154 guards tmpnam,
            \\leaving only a declaration marked
            \\__attribute__((__deprecated__("tmpnam is not defined on WASI"))),
            \\and stdio.h:64-67 guards L_tmpnam, so it is not defined at all;
            \\lib/libc/include/wasm-wasi-musl/stdlib.h:118-122 guards mkstemp,
            \\mkostemp and mkdtemp the same way. Nothing under lib/libc/wasi/
            \\defines either name - those headers are the only places the
            \\identifiers occur - so neither arm has an implementation to reach
            \\either, and silencing the deprecation would not turn L_tmpnam into
            \\a definition.
            \\
            \\In unchanged upstream bytes that is two errors, both in
            \\src/loslib.c: :173 sizes the buffer with the L_tmpnam the header
            \\does not define - and :13-17 includes errno.h, locale.h, stdlib.h,
            \\string.h and time.h, never stdio.h, so no include chain brings the
            \\macro in either - and :175 calls the tmpnam the header marks
            \\deprecated. LUA_USE_POSIX is not a way out: it moves the failure to
            \\:117, where mkstemp is equally undeclared, and it puts
            \\src/lua.c:47-57 back on sigaction, which this sysroot does not
            \\declare either.
            \\
            \\So the target is refused rather than patched past. No source is
            \\edited, tmpnam is not stubbed, and os is not dropped to make the
            \\rest of the library compile - dropping it would take os.time,
            \\os.date, os.clock, os.getenv, os.remove, os.rename and os.execute
            \\with it. Build for a target this package names a configuration
            \\for: x86_64-linux-gnu, aarch64-linux-gnu, riscv64-linux-gnu,
            \\aarch64-macos-none, x86_64-windows-gnu.
            \\
            \\This is a statement about this pinned src/loslib.c against this
            \\toolchain's WASI libc with nothing substituted for it, not a claim
            \\that WASI cannot host Lua. The cell comes back when upstream's
            \\:103 guard grows an arm for a platform with no temp directory, or
            \\when this toolchain's WASI libc stops removing mkstemp. Either is
            \\upstream's or the toolchain's to make, and this package makes
            \\neither.
            ,
        };
    }

    return null;
}

/// Reports the target refusal and stops the build.
fn refuseTarget(b: *std.Build, target: std.Build.ResolvedTarget) noreturn {
    const refusal = refusalFor(target.result.os.tag) orelse
        @panic("build.zig internal error: refusalFor returned null for a target addGraph refused");
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    std.log.err("lua: {s}: {s}\n{s}", .{ triple, refusal.summary, refusal.detail });
    @panic("lua: refusing a target this package has no buildable configuration for");
}

/// Ensures check targets are buildable and refused targets have a refusal.
fn checkMatrixPartition(b: *std.Build) void {
    for (check_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        if (refusalFor(resolved.result.os.tag) != null) {
            @panic(b.fmt(
                "build.zig: {s} is in check_targets but this build refuses its operating system",
                .{resolved.result.zigTriple(b.allocator) catch @panic("unspellable check target")},
            ));
        }
    }
    for (refused_check_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        if (refusalFor(resolved.result.os.tag) == null) {
            @panic(b.fmt(
                "build.zig: {s} is in refused_check_targets but refusalFor no longer refuses it; move it to check_targets and prove it builds",
                .{resolved.result.zigTriple(b.allocator) catch @panic("unspellable check target")},
            ));
        }
    }
}
