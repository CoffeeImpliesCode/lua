// SPDX-License-Identifier: MIT
// See ../FORK-LICENSE.md for what that identifier covers.

//! Consumes the `lua` package the way an outside project would.
//!
//! Everything here goes through the published surface only: `dep.module` in
//! `build.zig`, and `@import("lua")` here. No path reaches into the library's
//! own tree, so if this builds and produces the answers below, the module
//! contract is real: the typed facade, the translated headers it re-exports as
//! `c`, and the native library behind both arrived through one dependency line.
//!
//! The answers are facts about the Lua language that this SDK's `doc/` manual
//! states for these exact expressions, so they are independent of what the
//! library just did. Any mismatch exits non-zero.
//!
//! The same source builds against a linked package and against a
//! runtime-loaded one. `lua.runtime_loaded` is a comptime constant, so the
//! difference is one branch and no duplicated program: in the runtime-loaded
//! build the provider is named on the command line (`--provider <path>`) or in
//! `LUA_TEST_PROVIDER`, loaded once, and the same answers follow.

const std = @import("std");
const lua = @import("lua");

/// A runtime-loading build has no provider until one is named.
const ConfigurationError = error{NoProviderConfigured};

/// The provider this run should load, from `--provider <path>` or from
/// `LUA_TEST_PROVIDER`.
///
/// Both are explicit. Nothing here looks in a default location, and a build
/// that was not told which file to load says so rather than loading something
/// else.
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
        "consumer: this is a runtime-loading build. Pass --provider <path>, or " ++
            "export LUA_TEST_PROVIDER with a shared object exporting the 157 " ++
            "declarations of zig/translate.h. Nothing is loaded by default and " ++
            "no other file is tried.\n",
        .{},
    );
    return error.NoProviderConfigured;
}

/// A callback a dependent can register without this package's help: an
/// ordinary `callconv(.c)` function of Lua's own function-pointer type.
fn greet(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    const handle = state.?;
    const name = lua.c.luaL_checklstring(handle, 1, null);
    // `lua_pushfstring` is a C variadic: promoted arguments in a linked build,
    // one trailing tuple through the runtime-loaded dispatch. `runtime_loaded`
    // is comptime, so a dependent writes the branch once and needs no knowledge
    // of which of the two routes this build resolved.
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

    // In a runtime-loading build every call below goes through a table that
    // this one call fills. In a linked build the branch is not analyzed at all.
    if (comptime lua.runtime_loaded) {
        try lua.load(.{ .path = try providerRequest(init) });
    }

    try w.print("lua consumer\n", .{});
    // Through the raw escape hatch, so this line names the library this build
    // reached rather than a constant compiled into this program. It is printed,
    // not compared: a version string is provenance, not behaviour.
    try w.print("{s} provider reports: {s}\n", .{
        if (lua.runtime_loaded) "loaded" else "linked",
        lua.version_ident(),
    });

    // A dependent gets a state that owns itself and says what closing it means.
    var state = try lua.State.init();
    defer state.deinit();
    state.openLibraries();

    var text: [64]u8 = undefined;

    // A protected chunk, with the answer on the stack.
    try state.load("return 6 * 7", "=consumer", null);
    try state.pcall(0, 1, 0);
    try checkInt(w, "6 * 7", state.toInteger(-1) orelse return error.NoAnswer, 42);
    state.discardTop();

    // Integer arithmetic, the 64-bit wrap, and the float subtype.
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

    // Strings are byte sequences: the length is a byte count and an embedded
    // NUL is an ordinary byte.
    try checkInt(w, "#\"a\\0b\"", try evalInt(&state, "return #\"a\\0b\""), 3);
    const binary = [_]u8{ 0x00, 0xFF, 0x41 };
    _ = state.pushBytes(&binary);
    try checkInt(w, "binary length through the C API", state.rawLength(-1), 3);
    try checkBytes(w, "binary bytes round-trip", state.toBytes(-1) orelse return error.NoString, &binary);
    state.discardTop();

    // The string library's documented formatting.
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

    // A callback registered from this package and reached from a chunk.
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

    // The raw route, through the same module the facade uses: a declaration the
    // facade does not wrap, and a real C variadic.
    state.newTable(2, 0);
    const table_index = state.absIndex(-1);
    state.pushInteger(11);
    state.rawSetIndex(table_index, 1);
    state.pushInteger(22);
    state.rawSetIndex(table_index, 2);
    try checkInt(w, "raw luaL_len", lua.c.luaL_len(state.handle(), table_index), 2);
    state.discardTop();

    // The same C variadic from outside the library, reached through the
    // published module. `runtime_loaded` is comptime, so the one source
    // compiles against a linked package and a runtime-loaded one alike.
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
    // `{x}` on a byte slice is two hex digits per byte written straight to the
    // writer (`std/Io/Writer.zig`'s `printHex`), which is what makes the bytes
    // readable as bytes with nothing allocated to say it.
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
