// SPDX-License-Identifier: MIT
const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var command: std.ArrayList([]const u8) = .empty;
    {
        var target: std.Target = undefined;
        target.cpu.arch = std.meta.stringToEnum(std.Target.Cpu.Arch, args[2]).?;
        target.os.tag = std.meta.stringToEnum(std.Target.Os.Tag, args[3]).?;
        target.abi = std.meta.stringToEnum(std.Target.Abi, args[4]).?;
        target.dynamic_linker = .none;
        if (args[5].len != 0) target.dynamic_linker.set(args[5]);
        const root = args[6];
        const staged_prefix = args[7];
        const dest_dir = std.mem.trimEnd(u8, init.environ_map.get("DESTDIR") orelse "", "/\\");
        const prefix = if (dest_dir.len != 0 and staged_prefix.len > dest_dir.len and
            std.mem.startsWith(u8, staged_prefix, dest_dir) and
            std.fs.path.isSep(staged_prefix[dest_dir.len]))
            staged_prefix[dest_dir.len..]
        else
            staged_prefix;
        var darling = false;
        var qemu = false;
        var wasmtime = false;
        var wine = false;
        var runtimes: ?[]const u8 = null;
        var start: usize = 8;
        while (!std.mem.eql(u8, args[start], "--")) : (start += 1) {
            const arg = args[start];
            if (std.mem.eql(u8, arg, "-fdarling")) darling = true;
            if (std.mem.eql(u8, arg, "-fqemu")) qemu = true;
            if (std.mem.eql(u8, arg, "-fwasmtime")) wasmtime = true;
            if (std.mem.eql(u8, arg, "-fwine")) wine = true;
            if (std.mem.startsWith(u8, arg, "--libc-runtimes=") and arg.len > 16) runtimes = arg[16..];
            if (std.mem.startsWith(u8, arg, "--global-cache-dir=")) {
                try init.environ_map.put("ZIG_GLOBAL_CACHE_DIR", arg[19..]);
            }
        }
        const can_run = switch (std.zig.system.getExternalExecutor(io, &target, .{
            .host_cpu_arch = builtin.cpu.arch,
            .host_os_tag = builtin.os.tag,
            .qemu_fixes_dl = target.isGnuLibC() and runtimes != null,
            .link_mode = .dynamic,
            .link_libc = true,
        })) {
            .native => true,
            .rosetta => true,
            .qemu => qemu and !(target.isGnuLibC() and runtimes == null),
            .wine => wine,
            .wasmtime => wasmtime,
            .darling => darling,
            .bad_dl, .bad_os_or_cpu => false,
        };
        start += 1;
        try command.appendSlice(arena, args[start .. start + 2]);
        try command.append(arena, if (can_run) "run" else "install");
        for (args[8 .. start - 1]) |arg| {
            if (std.mem.startsWith(u8, arg, "--global-cache-dir=")) continue;
            if (std.mem.startsWith(u8, arg, "--libc-runtimes=")) {
                if (arg.len > 16) try command.appendSlice(arena, &.{ "--libc-runtimes", arg[16..] });
            } else {
                try command.append(arena, arg);
            }
        }
        const default_prefix = try std.fs.path.join(arena, &.{ root, "zig-out" });
        if (!std.mem.eql(u8, prefix, default_prefix)) {
            try command.appendSlice(arena, &.{ "--prefix", prefix });
        }
        try command.appendSlice(arena, args[start + 2 ..]);
    }
    var child = try std.process.spawn(io, .{ .argv = command.items, .environ_map = init.environ_map });
    switch (try child.wait(io)) {
        .exited => |code| std.process.exit(code),
        else => std.process.exit(1),
    }
}
