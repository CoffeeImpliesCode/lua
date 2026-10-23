// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! Deterministic smoke check for Lua 5.5 and the facade's stack, byte, and callback paths.
//! Expected values come from Lua's manual; a mismatch fails the program.
//! Runtime loading requires an explicit provider via `--provider` or `LUA_TEST_PROVIDER`.

const std = @import("std");
const lua = @import("lua");

/// Runtime builds require an explicitly named provider.
const ConfigurationError = error{NoProviderConfigured};

/// Return the explicit provider path from `--provider` or `LUA_TEST_PROVIDER`.
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

/// Report that runtime mode has no explicit provider.
fn noProvider() ConfigurationError {
    std.debug.print(
        "smoke: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export LUA_TEST_PROVIDER with a shared object exporting the 157 " ++
            "declarations of zig/translate.h. Nothing is loaded by default and " ++
            "no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

/// C callback returning three times its integer argument.
fn triple(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    const handle = state.?;
    // `luaL_checkinteger` may longjmp; Lua calls this callback inside `pcall`.
    const argument = lua.c.luaL_checkinteger(handle, 1);
    lua.c.lua_pushinteger(handle, argument * 3);
    return 1;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // Runtime mode must load its explicit provider before the facade calls.
    if (comptime lua.runtime_loaded) {
        try lua.load(.{ .path = try providerRequest(init) });
    }

    try w.print("lua smoke\n", .{});
    // Report the provider's own version as provenance, not a behavior check.
    try w.print("{s} provider reports: {s}\n", .{
        if (lua.runtime_loaded) "loaded" else "linked",
        lua.version_ident(),
    });
    try w.flush();

    var state = try lua.State.init();
    defer state.deinit();

    // A bare state has no libraries, and that is visible: `string` is nil.
    state.getGlobal("string");
    try checkType(&state, -1, .nil, "a fresh state has no standard libraries");

    state.openLibraries();
    state.getGlobal("string");
    try checkType(&state, -1, .table, "openLibraries installs the string library");
    state.discardTop();

    try state.load("return 6 * 7", "=smoke", null);
    try state.pcall(0, 1, 0);
    try checkInt(w, "6 * 7", state.toInteger(-1) orelse return error.NoAnswer, 42);
    state.discardTop();

    // Integer and float are two types, and the wrap is the 64-bit one.
    try checkInt(w, "7 // 2", try evalInt(&state, "return 7 // 2"), 3);
    try checkInt(w, "7 % 2", try evalInt(&state, "return 7 % 2"), 1);
    try checkInt(
        w,
        "maxinteger + 1 wraps to mininteger",
        try evalInt(&state, "return math.maxinteger + 1 == math.mininteger and 1 or 0"),
        1,
    );
    try checkFloat(w, "1 / 2", try evalFloat(&state, "return 1 / 2"), 0.5);

    // Bytes, including a NUL in the middle. `#` is the byte count, not the
    // distance to a NUL.
    var text: [64]u8 = undefined;
    try checkInt(w, "#\"a\\0b\" is three bytes", try evalInt(&state, "return #\"a\\0b\""), 3);
    const binary = [_]u8{ 'a', 0, 'b' };
    _ = state.pushBytes(&binary);
    const read_back = state.toBytes(-1) orelse return error.NoString;
    try checkBytes(w, "a NUL byte survives pushBytes and toBytes", read_back, &binary);
    state.discardTop();

    try checkString(
        w,
        "string.format",
        try evalString(
            &state,
            "return string.format('%d|%s|%5.2f', 42, 'hi', 3.14159)",
            &text,
        ),
        "42|hi| 3.14",
    );
    try checkString(
        w,
        "utf8.char(72, 105)",
        try evalString(&state, "return utf8.char(72, 105)", &text),
        "Hi",
    );

    state.register("triple", triple);
    try checkInt(w, "triple(7)", try evalInt(&state, "return triple(7)"), 21);

    // Failure leaves the error on top without moving the lower stack.
    const depth = state.getTop();
    const outcome = state.runChunk("error('deliberate')", "=smoke");
    try checkFailure(w, "error('deliberate')", outcome, error.RuntimeError);
    try checkInt(w, "one value was added to the stack", state.getTop(), depth + 1);
    const message = state.toBytes(-1) orelse return error.NoMessage;
    try w.print("{s: <44}{s}\n", .{ "runtime error message", message });
    state.discardError();

    // A compile failure is a different status and a different message.
    const compiled = state.runChunk("return +", "=smoke");
    try checkFailure(w, "return +", compiled, error.SyntaxError);
    const syntax = state.toBytes(-1) orelse return error.NoMessage;
    try w.print("{s: <44}{s}\n", .{ "compile error message", syntax });
    state.discardError();

    // Exercise the raw translated API and a real C variadic.
    state.newTable(3, 0);
    const table_index = state.absIndex(-1);
    state.pushInteger(10);
    state.rawSetIndex(table_index, 1);
    state.pushInteger(20);
    state.rawSetIndex(table_index, 2);
    state.pushInteger(30);
    state.rawSetIndex(table_index, 3);
    try checkInt(
        w,
        "raw luaL_len on a three-item array",
        lua.c.luaL_len(state.handle(), table_index),
        3,
    );
    state.discardTop();

    // Linked calls use promoted variadic args; runtime calls use a trailing tuple.
    const format = "%s=%d";
    const arguments = .{ "raw", @as(lua.Index, 7) };
    _ = if (comptime lua.runtime_loaded)
        lua.c.lua_pushfstring(state.handle(), format, arguments)
    else
        @call(.auto, lua.c.lua_pushfstring, .{ state.handle(), format } ++ arguments);
    const formatted = state.toBytes(-1) orelse return error.NoString;
    try checkString(w, "raw lua_pushfstring variadic", formatted, "raw=7");
    state.discardTop();

    try w.print("every answer matched the documented value\n", .{});
    try w.flush();
}

/// Evaluate source, return its integer result, and restore the stack.
fn evalInt(state: *lua.State, source: [:0]const u8) !i64 {
    const before = state.getTop();
    try state.load(source, "=smoke", null);
    try state.pcall(0, 1, 0);
    const value = state.toInteger(-1) orelse {
        state.setTop(before);
        return error.ResultIsNotAnInteger;
    };
    state.setTop(before);
    return value;
}

fn evalFloat(state: *lua.State, source: [:0]const u8) !f64 {
    const before = state.getTop();
    try state.load(source, "=smoke", null);
    try state.pcall(0, 1, 0);
    const value = state.toNumber(-1) orelse {
        state.setTop(before);
        return error.ResultIsNotANumber;
    };
    state.setTop(before);
    return value;
}

fn evalString(state: *lua.State, source: [:0]const u8, buffer: []u8) ![]const u8 {
    const before = state.getTop();
    try state.load(source, "=smoke", null);
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
        std.debug.print("smoke: {s}: expected {d}, computed {d}\n", .{ what, expected, got });
        return error.SmokeCheckFailed;
    }
}

fn checkFloat(w: *std.Io.Writer, what: []const u8, got: f64, expected: f64) !void {
    try w.print("{s: <44}{d}\n", .{ what, got });
    if (@abs(got - expected) > 1e-12) {
        std.debug.print("smoke: {s}: expected {d}, computed {d}\n", .{ what, expected, got });
        return error.SmokeCheckFailed;
    }
}

fn checkString(w: *std.Io.Writer, what: []const u8, got: []const u8, expected: []const u8) !void {
    try w.print("{s: <44}{s}\n", .{ what, got });
    if (!std.mem.eql(u8, got, expected)) {
        std.debug.print("smoke: {s}: expected \"{s}\", computed \"{s}\"\n", .{ what, expected, got });
        return error.SmokeCheckFailed;
    }
}

fn checkBytes(w: *std.Io.Writer, what: []const u8, got: []const u8, expected: []const u8) !void {
    try w.print("{s: <44}{d} bytes\n", .{ what, got.len });
    if (!std.mem.eql(u8, got, expected)) {
        // Format byte slices as hex directly, without allocating a copy.
        std.debug.print("smoke: {s}: expected {x}, computed {x}\n", .{
            what,
            expected,
            got,
        });
        return error.SmokeCheckFailed;
    }
}

fn checkType(state: *lua.State, index: lua.Index, expected: lua.Type, what: []const u8) !void {
    const got = state.typeOf(index);
    if (got != expected) {
        std.debug.print(
            "smoke: {s}: expected {s}, computed {s}\n",
            .{ what, @tagName(expected), @tagName(got) },
        );
        return error.SmokeCheckFailed;
    }
}

/// A call that was supposed to fail succeeded, or failed with another status.
fn checkFailure(w: *std.Io.Writer, what: []const u8, got: lua.Error!void, expected: lua.Error) !void {
    const err = if (got) |_| {
        std.debug.print("smoke: {s}: expected {s}, the call succeeded\n", .{
            what,
            @errorName(expected),
        });
        return error.SmokeCheckFailed;
    } else |failure| failure;
    try w.print("{s: <44}{s}\n", .{ what, @errorName(err) });
    if (err != expected) {
        std.debug.print("smoke: {s}: expected {s}, computed {s}\n", .{
            what,
            @errorName(expected),
            @errorName(err),
        });
        return error.SmokeCheckFailed;
    }
}
