// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! A runnable, deterministic demonstration of the Lua facade.
//!
//! `zig build smoke` runs this. There is no input to supply and no output that
//! depends on the host, the clock or a random seed, so the same lines come out
//! every time.
//!
//! Every answer below is an expected value, not a value this program computed
//! and printed for comparison. They are the ones the Lua 5.5 reference manual
//! in `doc/` states for these exact expressions. A mismatch prints both sides
//! and exits non-zero, so this is a check and not a demo.
//!
//! In a runtime-loading build the provider is named on the command line
//! (`--provider <path>`) or in `LUA_TEST_PROVIDER`, and the program says which
//! configuration it is in the first two lines. In a linked build neither is
//! needed and neither is read.
//!
//! What it exercises, in order: a state that owns itself, the standard
//! libraries, a protected chunk that returns a value, byte-exact strings with
//! an embedded NUL, an error object left exactly where upstream leaves it, a
//! callback registered from Zig and reached from Lua, and the raw translated
//! route for a declaration and a real C variadic the facade does not wrap.

const std = @import("std");
const lua = @import("lua");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// The provider this run should load, from `--provider <path>` or from
/// `LUA_TEST_PROVIDER`.
///
/// Both are explicit. Nothing here looks in a default location or falls back
/// to a linked copy: a runtime-loading build that was not told which file to
/// load reports that it was not told, rather than loading something else.
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

/// Say which variable is missing. An error name on its own would send the next
/// person into the loader instead of to the command line.
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

/// A C callback reached from Lua. Three times its argument, so the answer is a
/// fact about this program and about the boundary rather than about Lua.
fn triple(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    const handle = state.?;
    // The check is the raw route's `luaL_checkinteger` (`src/lauxlib.h:62`). It
    // raises through a longjmp when it is wrong, which is safe here and only
    // here: this function runs inside a `lua_pcall` that Lua itself established.
    const argument = lua.c.luaL_checkinteger(handle, 1);
    lua.c.lua_pushinteger(handle, argument * 3);
    return 1;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const w = &stdout.interface;

    // In a runtime-loading build nothing below can run until a provider is
    // loaded, and the load is the one explicit step the contract asks for. In a
    // linked build this is a no-op at comptime and the module is already
    // usable.
    if (comptime lua.runtime_loaded) {
        try lua.load(.{ .path = try providerRequest(init) });
    }

    try w.print("lua smoke\n", .{});
    // Through the raw escape hatch, so this line names the provider this build
    // reached rather than a constant compiled into this program. It is printed,
    // not compared: a version string is provenance, not behaviour.
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

    // A protected chunk, with a value left on the stack for the caller.
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

    // The standard library's own documented formatting.
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

    // A callback registered from Zig and reached from Lua.
    state.register("triple", triple);
    try checkInt(w, "triple(7)", try evalInt(&state, "return triple(7)"), 21);

    // A failed chunk, with the error object left exactly where upstream put it
    // and nothing below it moved.
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

    // The raw translated route: a declaration the facade does not wrap, and a
    // real C variadic with trailing arguments.
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

    // `lua_pushfstring` is a C variadic: promoted arguments in a linked build,
    // one trailing tuple through the runtime-loaded dispatch. The condition is
    // comptime, so only the route this build has is resolved, and the answer is
    // the same formatted string either way.
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

/// Run `source` and take its single integer result, leaving the stack as it was.
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
        // `{x}` on a byte slice is `printHex` writing two digits per byte
        // straight to the writer (`std/Io/Writer.zig`), so this says what the
        // bytes are without a buffer to hold a formatted copy in.
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
