// SPDX-License-Identifier: MIT
// See ../FORK-LICENSE.md for what that identifier covers.

//! Consumer example using only the published `lua` module.
//! Exercises known Lua results in linked and runtime-loading modes.

const std = @import("std");
const lua = @import("lua");

/// Error when runtime mode has no provider source.
const ConfigurationError = error{NoProviderConfigured};

/// Resolve an explicit provider from `--provider` or `LUA_TEST_PROVIDER`; no default path is used.
fn providerRequest(init: std.process.Init) ConfigurationError![]const u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch
        return noProvider();
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--provider")) {
            if (index + 1 >= args.len) return noProvider();
            return args[index + 1];
        }
    }
    return init.environ_map.get("LUA_TEST_PROVIDER") orelse
        return noProvider();
}

fn noProvider() ConfigurationError {
    std.debug.print(
        "consumer: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export LUA_TEST_PROVIDER with a shared object exporting the 157 " ++
            "declarations of zig/translate.h. Nothing is loaded by default and " ++
            "no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

/// C callback with the Lua function-pointer ABI.
fn greet(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    const handle = state.?;
    const name = lua.c.luaL_checklstring(handle, 1, null);
    // Linked calls use promoted varargs; runtime dispatch passes one tuple.
    // Comptime selection keeps the same consumer source valid for both modes.
    const format = "hello, %s";
    const arguments = .{name};
    _ = if (comptime lua.runtime_loaded)
        lua.c.lua_pushfstring(handle, format, arguments)
    else
        @call(.auto, lua.c.lua_pushfstring, .{ handle, format } ++ arguments);
    return 1;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // Load the provider before any routed call in runtime mode.
    if (comptime lua.runtime_loaded) {
        try lua.load(.{ .path = try providerRequest(init) });
    }

    try w.print("lua consumer\n", .{});
    try w.print("{s} provider reports: {s}\n", .{
        if (lua.runtime_loaded) "loaded" else "linked",
        lua.version_ident(),
    });

    var state = try lua.State.init();
    defer state.deinit();
    state.openLibraries();

    var text: [64]u8 = undefined;

    try state.load("return 6 * 7", "=consumer", null);
    try state.pcall(0, 1, 0);
    try checkInt(w, "6 * 7", state.toInteger(-1) orelse return error.NoAnswer, 42);
    state.discardTop();

    try checkInt(w, "7 // 2", try evalInt(&state, "return 7 // 2"), 3);
    try checkInt(w, "7 % 2", try evalInt(&state, "return 7 % 2"), 1);
    try checkInt(
        w,
        "maxinteger + 1 == mininteger",
        try evalInt(&state, "return math.maxinteger + 1 == math.mininteger and 1 or 0"),
        1,
    );
    try checkString(w, "math.type(3)", try evalString(&state, "return math.type(3)", &text), "integer");
    try checkString(w, "math.type(3.0)", try evalString(&state, "return math.type(3.0)", &text), "float");

    // Lua string length counts bytes; embedded NUL is ordinary data.
    try checkInt(w, "#\"a\\0b\"", try evalInt(&state, "return #\"a\\0b\""), 3);
    const binary = [_]u8{ 0x00, 0xFF, 0x41 };
    _ = state.pushBytes(&binary);
    try checkInt(w, "binary length through the C API", state.rawLength(-1), 3);
    try checkBytes(w, "binary bytes round-trip", state.toBytes(-1) orelse return error.NoString, &binary);
    state.discardTop();

    try checkString(
        w,
        "string.format",
        try evalString(&state, "return string.format('%d|%s|%5.2f', 42, 'hi', 3.14159)", &text),
        "42|hi| 3.14",
    );
    try checkString(
        w,
        "table.concat",
        try evalString(&state, "return table.concat({'a','b','c'}, '-')", &text),
        "a-b-c",
    );

    state.register("greet", greet);
    try checkString(
        w,
        "a C callback reached from Lua",
        try evalString(&state, "return greet('world')", &text),
        "hello, world",
    );

    // A failed chunk is an error and leaves exactly one value behind.
    const depth = state.getTop();
    const outcome = state.runChunk("error('deliberate')", "=consumer");
    if (outcome) |_| {
        std.debug.print("consumer: error('deliberate') was expected to fail\n", .{});
        return error.ConsumerCheckFailed;
    } else |err| {
        if (err != error.RuntimeError) {
            std.debug.print("consumer: error('deliberate') gave {s}\n", .{@errorName(err)});
            return error.ConsumerCheckFailed;
        }
        try w.print("{s: <44}{s}\n", .{ "error('deliberate')", @errorName(err) });
    }
    try checkInt(w, "one value was added to the stack", state.getTop(), depth + 1);
    try w.print("{s: <44}{s}\n", .{ "runtime error message", state.toBytes(-1) orelse return error.NoMessage });
    state.discardError();
    try checkInt(w, "the stack is back where it was", state.getTop(), depth);

    // Exercise an unwrapped declaration and C variadic through the published raw module.
    state.newTable(2, 0);
    const table_index = state.absIndex(-1);
    state.pushInteger(11);
    state.rawSetIndex(table_index, 1);
    state.pushInteger(22);
    state.rawSetIndex(table_index, 2);
    try checkInt(w, "raw luaL_len", lua.c.luaL_len(state.handle(), table_index), 2);
    state.discardTop();

    const format = "%s/%d";
    const arguments = .{ "consumer", @as(lua.Index, 1) };
    _ = if (comptime lua.runtime_loaded)
        lua.c.lua_pushfstring(state.handle(), format, arguments)
    else
        @call(.auto, lua.c.lua_pushfstring, .{ state.handle(), format } ++ arguments);
    try checkString(
        w,
        "raw lua_pushfstring variadic",
        state.toBytes(-1) orelse return error.NoString,
        "consumer/1",
    );
    state.discardTop();

    try w.print("every answer matched the documented value\n", .{});
    try w.flush();
}

fn evalInt(state: *lua.State, source: [:0]const u8) !i64 {
    const before = state.getTop();
    try state.load(source, "=consumer", null);
    try state.pcall(0, 1, 0);
    const value = state.toInteger(-1) orelse {
        state.setTop(before);
        return error.ResultIsNotAnInteger;
    };
    state.setTop(before);
    return value;
}

fn evalString(state: *lua.State, source: [:0]const u8, buffer: []u8) ![]const u8 {
    const before = state.getTop();
    try state.load(source, "=consumer", null);
    try state.pcall(0, 1, 0);
    const value = state.toBytes(-1) orelse {
        state.setTop(before);
        return error.ResultIsNotAString;
    };
    if (value.len > buffer.len) {
        state.setTop(before);
        return error.BufferTooSmall;
    }
    @memcpy(buffer[0..value.len], value);
    state.setTop(before);
    return buffer[0..value.len];
}

fn checkInt(w: *std.Io.Writer, what: []const u8, got: anytype, expected: anytype) !void {
    try w.print("{s: <44}{d}\n", .{ what, got });
    if (got != expected) {
        std.debug.print("consumer: {s}: expected {d}, computed {d}\n", .{ what, expected, got });
        return error.ConsumerCheckFailed;
    }
}

fn checkString(w: *std.Io.Writer, what: []const u8, got: []const u8, expected: []const u8) !void {
    try w.print("{s: <44}{s}\n", .{ what, got });
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print("consumer: {s}: expected \"{s}\", computed \"{s}\"\n", .{
            what,
            expected,
            got,
        });
        return error.ConsumerCheckFailed;
    }
}

fn checkBytes(w: *std.Io.Writer, what: []const u8, got: []const u8, expected: []const u8) !void {
    // Format bytes as hexadecimal directly through the writer.
    try w.print("{s: <44}{x}\n", .{ what, got });
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print("consumer: {s}: expected {x}, computed {x}\n", .{
            what,
            expected,
            got,
        });
        return error.ConsumerCheckFailed;
    }
}
