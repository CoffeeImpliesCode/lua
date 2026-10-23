// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! Tests Lua semantics and the facade's stack, ownership, and byte-string contracts.
//! Lua allocates through libc; `std.testing.allocator` cannot count Lua-owned memory.
//! Language expectations come from Lua's reference manual.

const std = @import("std");
const lua = @import("lua");
const testing = std.testing;

/// Load the explicit provider once when runtime dispatch is enabled.
const provider_variable = "LUA_TEST_PROVIDER";
fn nativeReady() void {
    if (comptime !lua.runtime_loaded) return;
    if (lua.loadedSource() != null) return;

    var buffer: [4096]u8 = undefined;
    const value = std.testing.environ.getAlloc(testing.allocator, provider_variable) catch
        missingProvider();
    defer testing.allocator.free(value);
    if (value.len == 0 or value.len > buffer.len) missingProvider();
    @memcpy(buffer[0..value.len], value);
    lua.load(.{ .path = buffer[0..value.len] }) catch |err| {
        std.debug.print(
            "tests.zig: loading " ++ provider_variable ++ " = \"{s}\" failed: {t}\n",
            .{ buffer[0..value.len], err },
        );
        @panic("tests.zig: the provider named by " ++ provider_variable ++
            " did not load; nothing below this line ran");
    };
}

fn missingProvider() noreturn {
    @panic(
        "tests.zig: this is a runtime-loading build and " ++ provider_variable ++
            " is not set. Point it at a shared object exporting the 157 " ++
            "declarations of zig/translate.h, for example the one `zig build " ++
            "-Dlinkage=dynamic` installs, and export it for the whole `zig build` " ++
            "invocation: the build cannot inject a path into a run step's " ++
            "environment.",
    );
}

/// Run source and return its integer result, restoring the stack.
fn evalInt(state: *lua.State, source: [:0]const u8) !i64 {
    const before = state.getTop();
    try state.load(source, "=test", null);
    try state.pcall(0, 1, 0);
    const value = state.toInteger(-1) orelse {
        state.setTop(before);
        return error.ResultIsNotAnInteger;
    };
    state.setTop(before);
    return value;
}

/// Run source and return its float result, restoring the stack.
fn evalFloat(state: *lua.State, source: [:0]const u8) !f64 {
    const before = state.getTop();
    try state.load(source, "=test", null);
    try state.pcall(0, 1, 0);
    const value = state.toNumber(-1) orelse {
        state.setTop(before);
        return error.ResultIsNotANumber;
    };
    state.setTop(before);
    return value;
}

/// Run source and copy its string result into caller-owned `buffer`.
fn evalString(state: *lua.State, source: [:0]const u8, buffer: []u8) ![]const u8 {
    const before = state.getTop();
    try state.load(source, "=test", null);
    try state.pcall(0, 1, 0);
    const text = state.toBytes(-1) orelse {
        state.setTop(before);
        return error.ResultIsNotAString;
    };
    if (text.len > buffer.len) {
        state.setTop(before);
        return error.BufferTooSmall;
    }
    @memcpy(buffer[0..text.len], text);
    state.setTop(before);
    return buffer[0..text.len];
}

/// Run source and require one boolean result.
fn evalBool(state: *lua.State, source: [:0]const u8) !bool {
    const before = state.getTop();
    try state.load(source, "=test", null);
    try state.pcall(0, 1, 0);
    if (state.typeOf(-1) != .boolean) {
        state.setTop(before);
        return error.ResultIsNotABoolean;
    }
    const value = state.toBoolean(-1);
    state.setTop(before);
    return value;
}

test "arithmetic follows the Lua 5.5 integer and float rules" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // Lua integer arithmetic wraps at 64 bits; this test compares through a boolean.
    try testing.expectEqual(@as(i64, 42), try evalInt(&state, "return 6 * 7"));
    try testing.expectEqual(@as(i64, 3), try evalInt(&state, "return 7 // 2"));
    try testing.expectEqual(@as(i64, 1), try evalInt(&state, "return 7 % 2"));
    try testing.expect(try evalBool(&state, "return math.maxinteger + 1 == math.mininteger"));

    // `/` is float; `//` on floats truncates toward zero and stays float.
    try testing.expectApproxEqAbs(@as(f64, 0.5), try evalFloat(&state, "return 1 / 2"), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1024.0), try evalFloat(&state, "return 2 ^ 10"), 1e-9);
    try testing.expectApproxEqAbs(
        @as(f64, 3.0),
        try evalFloat(&state, "return 7 // 2.0"),
        1e-12,
    );

    // Lua distinguishes integer and float subtypes.
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "integer",
        try evalString(&state, "return math.type(3)", &buffer),
    );
    try testing.expectEqualStrings(
        "float",
        try evalString(&state, "return math.type(3.0)", &buffer),
    );
}

test "strings are byte sequences and keep every byte" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // String length counts bytes, including embedded NUL.
    try testing.expectEqual(
        @as(lua.Index, 3),
        try evalInt(&state, "return #\"a\\0b\""),
    );

    const payload = [_]u8{ 'a', 0, 'b' };
    try testing.expectEqualSlices(u8, &payload, state.pushBytes(&payload));
    try testing.expectEqual(@as(usize, 3), state.rawLength(-1));
    const read_back = state.toBytes(-1) orelse return error.NoString;
    try testing.expectEqualSlices(u8, &payload, read_back);

    // A Lua string literal also preserves an embedded NUL.
    var buffer: [8]u8 = undefined;
    const text = try evalString(&state, "return \"a\\0b\"", &buffer);
    try testing.expectEqualSlices(u8, &payload, text);

    // Lua strings preserve non-UTF-8 bytes.
    const high = [_]u8{ 0xC3, 0x28, 0xFF };
    _ = state.pushBytes(&high);
    try testing.expectEqual(@as(usize, 3), state.rawLength(-1));
    try testing.expectEqualSlices(u8, &high, state.toBytes(-1) orelse return error.NoString);
    state.discardTop();
}

test "a failed call leaves exactly one value on the stack and nothing else moved" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // Values below the call verify the lower stack remains unchanged.
    state.pushInteger(11);
    state.pushInteger(22);
    state.pushInteger(33);
    const depth_before = state.getTop();
    try testing.expectEqual(@as(lua.Index, 3), depth_before);

    try testing.expectError(error.RuntimeError, state.runChunk("error('boom')", "=demo"));
    try testing.expectEqual(depth_before + 1, state.getTop());
    try testing.expectEqual(lua.Type.string, state.typeOf(-1));

    var buffer: [256]u8 = undefined;
    const message = try state.takeError(&buffer);
    // Lua prefixes the message with the chunk name and line.
    try testing.expect(std.mem.startsWith(u8, message, "demo:1: boom"));
    try testing.expectEqual(depth_before, state.getTop());
    try testing.expectEqual(@as(i64, 33), state.toInteger(-1) orelse return error.NoInteger);

    // Syntax errors have a distinct status and leave the compiler message.
    try testing.expectError(error.SyntaxError, state.runChunk("return +", "=demo"));
    try testing.expectEqual(depth_before + 1, state.getTop());
    const syntax = state.errorMessage() orelse return error.NoMessage;
    try testing.expect(std.mem.startsWith(u8, syntax, "demo:1:"));
    state.discardError();
    try testing.expectEqual(depth_before, state.getTop());
}

test "an error object that is not a string is reported, not smoothed over" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    try testing.expectError(
        error.RuntimeError,
        state.runChunk("error({code = 7})", "=objects"),
    );
    try testing.expectEqual(lua.Type.table, state.typeOf(-1));
    try testing.expectEqual(@as(?[]const u8, null), state.errorMessage());
    try testing.expectEqualStrings("table", state.typeNameAt(-1) orelse return error.NoTypeName);
    state.discardError();

    // Reading a numeric error with `toBytes` converts that stack slot in place.
    try testing.expectError(
        error.RuntimeError,
        state.runChunk("error(42)", "=numbers"),
    );
    try testing.expectEqual(lua.Type.number, state.typeOf(-1));
    try testing.expectEqualStrings("42", state.errorMessage() orelse return error.NoMessage);
    try testing.expectEqual(lua.Type.string, state.typeOf(-1));

    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("42", try state.takeError(&buffer));
    try testing.expectEqual(@as(lua.Index, 0), state.getTop());
}

test "takeError leaves the value alone when it cannot take it" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    try testing.expectError(
        error.RuntimeError,
        state.runChunk("error('kept')", "=resid"),
    );
    const depth = state.getTop();
    // Failed `takeError` must preserve the original value and stack slot.
    const kept = state.errorMessage() orelse return error.NoMessage;
    const kept_address = state.toPointer(-1) orelse return error.NoPointer;

    // A too-small buffer leaves the error available for a retry.
    var tiny: [2]u8 = undefined;
    try testing.expectError(
        error.ErrorBufferTooSmall,
        state.takeError(&tiny),
    );
    try testing.expectEqual(depth, state.getTop());
    try testing.expectEqual(lua.Type.string, state.typeOf(-1));
    try testing.expectEqual(kept_address, state.toPointer(-1) orelse return error.NoPointer);
    try testing.expectEqualStrings(kept, state.errorMessage() orelse return error.NoMessage);

    try testing.expectError(
        error.RuntimeError,
        state.runChunk("error(setmetatable({}, {}))", "=resid"),
    );
    try testing.expectError(error.NoErrorMessage, state.takeError(&tiny));
    try testing.expectEqual(lua.Type.table, state.typeOf(-1));
    state.discardError();
}

test "a message handler replaces the error object, and nothing else moves" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // The handler sits below the function, so pcall's zero argument count is valid.
    state.pushCClosure(replaceMessage, 0);
    try testing.expectEqual(@as(lua.Index, 1), state.absIndex(-1));
    try state.load("error('original')", "=handled", null);
    const call_depth = state.getTop();
    try testing.expectError(error.RuntimeError, state.pcall(0, 0, 1));

    // Protected failure restores stack depth and replaces only the function slot.
    try testing.expectEqual(call_depth, state.getTop());
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("replaced", try state.takeError(&buffer));

    // `takeError` removes only the error; the handler remains below it.
    try testing.expectEqual(call_depth - 1, state.getTop());
    try testing.expectEqual(lua.Type.function, state.typeOf(1));
}

test "openLibraries is what puts the libraries in the globals table" {
    nativeReady();

    // A bare state has no libraries; `initWithLibraries` opens them.
    var bare = try lua.State.init();
    defer bare.deinit();
    bare.getGlobal("string");
    try testing.expectEqual(lua.Type.nil, bare.typeOf(-1));
    try testing.expectError(
        error.RuntimeError,
        bare.runChunk("return string.format('%d', 1)", "=bare"),
    );
    bare.discardError();

    // The same chunk succeeds after opening libraries.
    var full = try lua.State.initWithLibraries();
    defer full.deinit();
    full.getGlobal("string");
    try testing.expectEqual(lua.Type.table, full.typeOf(-1));
    full.discardTop();
    var answer: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "1",
        try evalString(&full, "return string.format('%d', 1)", &answer),
    );

    var one = try lua.State.init();
    defer one.deinit();
    one.openLibrary(.math);
    one.getGlobal("math");
    try testing.expectEqual(lua.Type.table, one.typeOf(-1));
    one.discardTop();
    one.getGlobal("string");
    try testing.expectEqual(lua.Type.nil, one.typeOf(-1));
    one.discardTop();

    // Compare with Lua's documented `string.format` behavior.
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "42|hi| 3.14",
        try evalString(
            &full,
            "return string.format('%d|%s|%5.2f', 42, 'hi', 3.14159)",
            &buffer,
        ),
    );
    try testing.expectEqualStrings(
        "3-1-2",
        try evalString(&full, "return table.concat({3,1,2}, '-')", &buffer),
    );
    try testing.expectEqualStrings("Hi", try evalString(&full, "return utf8.char(72, 105)", &buffer));
}

test "a callback registered from Zig is called by Lua, and its error stays inside pcall" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    state.register("triple", triple);
    state.register("explode", explode);

    try testing.expectEqual(@as(i64, 21), try evalInt(&state, "return triple(7)"));

    // A callback longjmp inside `pcall` returns as a protected error.
    const before = state.getTop();
    try testing.expectError(
        error.RuntimeError,
        state.runChunk("return explode()", "=callback"),
    );
    try testing.expectEqual(before + 1, state.getTop());
    var buffer: [128]u8 = undefined;
    const message = try state.takeError(&buffer);
    try testing.expect(std.mem.startsWith(u8, message, "callback:1: exploded in C"));

    try testing.expectEqual(@as(i64, 21), try evalInt(&state, "return triple(7)"));
}

/// Error handler that replaces the message and returns normally.
fn replaceMessage(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    const handle = state.?;
    _ = lua.c.lua_pushstring(handle, "replaced");
    return 1;
}

/// C callback returning three times its integer argument.
fn triple(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    const handle = state.?;
    // `luaL_checkinteger` may longjmp because Lua invokes this callback protected.
    const argument = lua.c.luaL_checkinteger(handle, 1);
    lua.c.lua_pushinteger(handle, argument * 3);
    return 1;
}

/// C callback that raises a Lua error through `luaL_error`.
fn explode(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    // Variadic arguments use the linked or runtime dispatch shape at comptime.
    const handle = state.?;
    return if (comptime lua.runtime_loaded)
        lua.c.luaL_error(handle, "exploded in C", .{})
    else
        @call(.auto, lua.c.luaL_error, .{ handle, "exploded in C" });
}

/// Records whether a finalizer ran and what it observed.
const Observation = struct {
    fired: bool = false,
    answer: ?bool = null,
};

/// Finalizer callback that records collector state through a borrowed state view.
fn recordCollection(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    const handle = state.?;
    const record: **Observation = @ptrCast(@alignCast(lua.c.lua_touserdata(handle, 1).?));
    // This view does not own or close the Lua state.
    var observer = lua.State{ .raw = handle };
    record.*.answer = observer.isCollecting();
    record.*.fired = true;
    return 0;
}

/// Add userdata whose finalizer writes to `record`.
fn armFinalizer(state: *lua.State, record: *Observation) void {
    _ = lua.c.lua_newuserdatauv(state.handle(), @sizeOf(*Observation), 0);
    const cell: **Observation = @ptrCast(@alignCast(lua.c.lua_touserdata(state.handle(), -1).?));
    cell.* = record;

    // Collection finalizes unreachable objects; close runs every pending finalizer.
    lua.c.lua_newtable(state.handle());
    lua.c.lua_pushcfunction(state.handle(), &recordCollection);
    lua.c.lua_setfield(state.handle(), -2, "__gc");
    _ = lua.c.lua_setmetatable(state.handle(), -2);
}

test "isCollecting answers upstream, and has no answer inside a finalizer" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // The accessor distinguishes running, explicitly stopped, and refused collection.
    try testing.expectEqual(@as(?bool, true), state.isCollecting());
    state.stopGarbageCollector();
    try testing.expectEqual(@as(?bool, false), state.isCollecting());
    state.restartGarbageCollector();
    try testing.expectEqual(@as(?bool, true), state.isCollecting());

    // A finalizer runs during collection, when Lua refuses the selector.
    var collected: Observation = .{};
    armFinalizer(&state, &collected);
    state.setTop(0);
    state.collectGarbage();
    state.collectGarbage();
    try testing.expect(collected.fired);
    try testing.expectEqual(@as(?bool, null), collected.answer);
}

test "a finalizer a close runs has no answer either" {
    nativeReady();
    var state = try lua.State.initWithLibraries();

    // Closing runs pending finalizers while the collector is unavailable.
    var closing: Observation = .{};
    armFinalizer(&state, &closing);
    state.deinit();
    try testing.expect(closing.fired);
    try testing.expectEqual(@as(?bool, null), closing.answer);
}

test "the collector does not change what a state computes" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    try state.load(build_garbage, "=garbage", null);
    try state.pcall(0, 0, 0);
    try testing.expectEqual(@as(lua.Index, 0), state.getTop());

    // A reachable table keeps its identity across collection.
    state.newTable(0, 0);
    const kept = state.absIndex(-1);
    const kept_address = state.toPointer(kept) orelse return error.NoPointer;
    state.collectGarbage();
    try testing.expectEqual(
        kept_address,
        state.toPointer(kept) orelse return error.NoPointer,
    );

    // Values stored in the table survive another collection.
    _ = state.pushBytes("still here");
    state.rawSetIndex(kept, 1);
    state.collectGarbage();
    state.rawGetIndex(kept, 1);
    try testing.expectEqualStrings("still here", state.toBytes(-1) orelse return error.NoBytes);
    state.discardTop();
    state.discardTop();

    state.stopGarbageCollector();
    state.collectGarbage();
    state.restartGarbageCollector();
    state.collectGarbage();
    try testing.expectEqual(@as(i64, 2), try evalInt(&state, "return #({1, 2})"));
}

/// Tracks the sizes passed to Lua's custom allocator callback.
const Counter = struct {
    live: usize = 0,

    fn record(self: *Counter, ptr: ?*anyopaque, osize: usize, nsize: usize) void {
        if (ptr == null) {
            self.live += nsize;
            return;
        }
        if (nsize == 0) {
            self.live -= osize;
            return;
        }
        self.live += nsize;
        self.live -= osize;
    }
};

/// Count allocator requests and forward them to libc.
fn countingAlloc(
    ud: ?*anyopaque,
    ptr: ?*anyopaque,
    osize: usize,
    nsize: usize,
) callconv(.c) ?*anyopaque {
    const counter: *Counter = @ptrCast(@alignCast(ud.?));
    counter.record(ptr, osize, nsize);
    if (nsize == 0) return null;
    const block = ptr orelse return std.c.malloc(nsize);
    return std.c.realloc(block, nsize);
}

test "the collector counts the bytes it is holding, exactly" {
    nativeReady();
    var counter: Counter = .{};

    // Use `lua_newstate` so the test observes Lua's actual allocator requests.
    var state: lua.State = .{
        .raw = lua.c.lua_newstate(countingAlloc, &counter, 0) orelse return error.NoState,
    };
    defer state.deinit();
    state.openLibraries();

    // A user-stopped collector still answers allocation counts.
    state.stopGarbageCollector();

    // Collect until the remainder is nonzero so both count selectors are tested.
    var filler: [64]u8 = undefined;
    var length: usize = 0;
    var reported: f64 = 0;
    while (true) {
        // Compare against Lua's documented `collectgarbage("count")` result.
        reported = try evalFloat(&state, "return collectgarbage('count') * 1024");
        if ((@as(usize, @intFromFloat(reported)) & 0x3ff) != 0) break;
        length += 1;
        if (length > filler.len) return error.NoRemainderBelowAKibibyte;
        @memset(filler[0..length], 'x');
        _ = state.pushBytes(filler[0..length]);
    }

    const live = counter.live;
    try testing.expect(live > 1024);
    try testing.expectEqual(@as(f64, @floatFromInt(live)), reported);

    try testing.expectEqual(
        @as(c_int, @intCast(live >> 10)),
        state.garbageKilobytes().?,
    );
    try testing.expectEqual(live, state.garbageBytes().?);
}

// Separate statements so the loop terminator and next name do not merge.
const build_garbage =
    "local sink = {}\n" ++
    "for i = 1, 500 do sink[i] = {index = i, text = string.rep('x', i)} end\n" ++
    "sink = nil";

test "stack positions behave as the manual says they do" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    try testing.expectEqual(@as(lua.Index, 0), state.getTop());
    state.pushInteger(1);
    state.pushInteger(2);
    state.pushInteger(3);

    // Negative indices count from the top; `absIndex` rebases before stack-moving calls.
    try testing.expectEqual(@as(lua.Index, 1), state.absIndex(-3));
    try testing.expectEqual(@as(lua.Index, 3), state.absIndex(-1));
    try testing.expectEqual(@as(lua.Index, 3), state.getTop());

    // `checkStack` reserves slots beyond Lua's guaranteed minimum.
    try testing.expect(state.checkStack(@intCast(lua.min_stack + 1)));
    try testing.expectEqual(@as(lua.Index, 3), state.getTop());

    state.setTop(1);
    try testing.expectEqual(@as(lua.Index, 1), state.getTop());

    state.getGlobal("string");
    const table_index = state.absIndex(-1);
    state.pushValue(table_index);
    try testing.expect(state.rawEqual(table_index, -1));
    state.discardTop();

    // `==` honors `__eq`; `rawequal` compares identity.
    try testing.expectEqual(
        @as(i64, 1),
        try evalInt(&state, equality_with_metamethod),
    );
}

const equality_with_metamethod =
    "local mt = {__eq = function() return true end}" ++
    "local a = setmetatable({}, mt)" ++
    "local b = setmetatable({}, mt)" ++
    "return ((a == b) and 1 or 0) + (rawequal(a, b) and 1 or 0)";

test "closing a state is a transition this module owns" {
    nativeReady();

    var state = try lua.State.initWithLibraries();
    try testing.expect(state.isOpen());
    try testing.expectEqual(@as(i64, 42), try evalInt(&state, "return 6 * 7"));
    state.deinit();
    try testing.expect(!state.isOpen());

    // `deinit` clears the handle, preventing a second close.
    state.deinit();
    try testing.expect(!state.isOpen());

    // Closing one state does not close another.
    var first = try lua.State.initWithLibraries();
    var second = try lua.State.initWithLibraries();
    try testing.expectEqual(@as(i64, 1), try evalInt(&first, "return 1"));
    first.deinit();
    try testing.expect(!first.isOpen());
    try testing.expectEqual(@as(i64, 2), try evalInt(&second, "return 2"));
    second.deinit();

    // A new state does not inherit globals from a closed state.
    var third = try lua.State.initWithLibraries();
    defer third.deinit();
    _ = third.pushBytes("carried");
    third.setGlobal("carried");
    third.deinit();

    var fourth = try lua.State.initWithLibraries();
    defer fourth.deinit();
    fourth.getGlobal("carried");
    try testing.expectEqual(lua.Type.nil, fourth.typeOf(-1));
    fourth.discardTop();
}

test "a thread is a value on the stack, and the parent owns it" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // `ThreadRef` borrows the parent stack anchor and must not outlive it.
    {
        const thread = state.newThread();
        try testing.expectEqual(lua.Type.thread, state.typeOf(-1));

        const from_stack = state.toThread(-1) orelse return error.NotAThread;
        try testing.expectEqual(thread.handle(), from_stack.handle());
        state.discardTop();
    }

    var buffer: [64]u8 = undefined;

    try testing.expectEqualStrings(
        "42",
        try evalString(&state, resume_multiplier, &buffer),
    );

    // Resume reports failure and preserves the error-text tail and status.
    const failure = try evalString(&state, resume_failure, &buffer);
    try testing.expect(std.mem.endsWith(u8, failure, ": inside"));
    try testing.expect(!try evalBool(&state, resume_failure_status));

    try testing.expectEqualStrings(
        "1 2",
        try evalString(&state, resume_yield_twice, &buffer),
    );
}

/// C callback returning twice its integer argument.
fn doubleArgument(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    const handle = state.?;
    lua.c.lua_pushinteger(handle, lua.c.luaL_checkinteger(handle, 1) * 2);
    return 1;
}

test "resuming a coroutine reports what it left on its own stack" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // The parent owns the coroutine; this view never closes it.
    const runner = state.newThread();
    lua.c.lua_pushcclosure(runner.handle(), doubleArgument, 0);
    lua.c.lua_pushinteger(runner.handle(), 21);

    const produced = try runner.@"resume"(1);
    try testing.expectEqual(@as(usize, 1), produced);

    // Move the coroutine's result to the parent stack with `lua_xmove`.
    lua.c.lua_xmove(runner.handle(), state.handle(), 1);
    try testing.expectEqual(@as(i64, 42), state.toInteger(-1) orelse return error.NoInteger);
    state.discardTop();
    state.discardTop();
}

test "statusOf reads the status upstream leaves on a thread" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    try testing.expectEqual(lua.Status.ok, try state.statusOf());
    try state.runChunk("return 6 * 7", "=status");
    try testing.expectEqual(lua.Status.ok, try state.statusOf());

    // Read coroutine status through a temporary non-owning `State` view.
    const runner = state.newThread();
    var runner_view = lua.State{ .raw = runner.handle() };
    try runner_view.loadChunk("coroutine.yield(1)", "=yielding");
    try testing.expectError(error.RuntimeError, runner.@"resume"(0));
    try testing.expectEqual(lua.Status.yield, try runner_view.statusOf());

    try testing.expectEqual(@as(usize, 0), try runner.@"resume"(0));
    try testing.expectEqual(lua.Status.ok, try runner_view.statusOf());

    try runner_view.loadChunk("error('inside')", "=failing");
    try testing.expectError(error.RuntimeError, runner.@"resume"(0));
    try testing.expectEqual(lua.Status.runtime, try runner_view.statusOf());

    // A valid provider cannot produce `UnexpectedStatus`; that requires a malformed provider.
}

const resume_multiplier =
    "local co = coroutine.create(function(a, b) return a * b end)" ++
    "local ok, value = coroutine.resume(co, 6, 7)" ++
    "return tostring(value)";

/// The error text from a resumed coroutine; upstream prefixes its source position.
const resume_failure =
    "local co = coroutine.create(function() error('inside') end)" ++
    "local ok, message = coroutine.resume(co)" ++
    "return message";

/// Whether the resumed coroutine failed rather than returned a value.
const resume_failure_status =
    "local co = coroutine.create(function() error('inside') end)" ++
    "local ok = coroutine.resume(co)" ++
    "return ok";

const resume_yield_twice =
    "local co = coroutine.wrap(function() coroutine.yield(1) return 2 end)" ++
    "return tostring(co()) .. ' ' .. tostring(co())";

test "the raw route reaches declarations and spellings the facade does not name" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // Exercise a real C variadic through both linked and runtime dispatch.
    const format = "%s=%d";
    const arguments = .{ "n", @as(lua.Index, 7) };
    _ = if (comptime lua.runtime_loaded)
        lua.c.lua_pushfstring(state.handle(), format, arguments)
    else
        @call(.auto, lua.c.lua_pushfstring, .{ state.handle(), format } ++ arguments);
    try testing.expectEqualStrings("n=7", state.toBytes(-1) orelse return error.NoString);
    state.discardTop();

    // Exercise a raw translated declaration the facade does not wrap.
    state.newTable(3, 0);
    const table_index = state.absIndex(-1);
    state.pushInteger(1);
    state.rawSetIndex(table_index, 1);
    state.pushInteger(2);
    state.rawSetIndex(table_index, 2);
    state.pushInteger(3);
    state.rawSetIndex(table_index, 3);
    try testing.expectEqual(@as(i64, 3), lua.c.luaL_len(state.handle(), table_index));
    state.discardTop();

    // Call the byte APIs directly through translated C declarations.
    const payload = [_]u8{ 0x00, 0x7F, 0x80, 0xFF };
    _ = lua.c.lua_pushlstring(state.handle(), &payload, payload.len);
    var length: usize = 0;
    const text = lua.c.lua_tolstring(state.handle(), -1, &length);
    try testing.expectEqual(payload.len, length);
    try testing.expectEqualSlices(u8, &payload, text[0..length]);
    state.discardTop();

    // Verify that the provider's banner contains Lua's compiled release.
    const ident = lua.version_ident();
    try testing.expect(ident.len > 0);
    var banner: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&banner, "Lua {d}.{d}.{d}", .{
        @as(u32, @intCast(lua.version_num / 100)),
        @as(u32, @intCast(lua.version_num % 100)),
        @as(u32, @intCast(lua.version_release_num - lua.version_num * 100)),
    });
    try testing.expect(std.mem.indexOf(u8, ident, expected) != null);
}

test "the numeric type boundary is observable, not assumed" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // An integer beyond f64 precision remains exact through `toInteger`.
    state.pushInteger(9007199254740993);
    try testing.expectEqual(@as(i64, 9007199254740993), state.toInteger(-1) orelse return error.NoInteger);
    // `toNumber` converts that integer to its rounded f64 value.
    const as_float = state.toNumber(-1) orelse return error.NoNumber;
    try testing.expectApproxEqAbs(@as(f64, 9007199254740992.0), as_float, 1.0);
    state.discardTop();

    _ = state.pushBytes("not a number");
    try testing.expectEqual(@as(?f64, null), state.toNumber(-1));
    try testing.expectEqual(@as(?i64, null), state.toInteger(-1));
    state.discardTop();

    try testing.expect(try evalBool(&state, "return math.mininteger - 1 == math.maxinteger"));
}

test "stack values keep their identity through push and get" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    state.newTable(0, 0);
    const first = state.absIndex(-1);
    state.pushValue(first);
    const second = state.absIndex(-1);
    try testing.expectEqual(
        state.toPointer(first) orelse return error.NoPointer,
        state.toPointer(second) orelse return error.NoPointer,
    );

    state.newTable(0, 0);
    const third = state.absIndex(-1);
    try testing.expect(state.toPointer(first) != state.toPointer(third));

    try testing.expectEqual(@as(?[]const u8, null), state.toBytes(third));
    try testing.expectEqual(lua.Type.table, state.typeOf(third));
}
