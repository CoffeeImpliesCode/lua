// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! Behavioural tests for the Lua facade.
//!
//! Nothing here pins a version, an export list or a default, and nothing
//! compares a forwarding accessor with the thing it forwards to. Every
//! expectation is either a fact about the Lua language that this SDK's headers
//! and documentation state, or an observation about a boundary this package
//! owns: what a failed protected call leaves on the stack, what `openLibraries`
//! actually installs, what a binary string survives, and what closing a state
//! does to the state handle afterwards.
//!
//! ## Where the answers come from
//!
//! The language facts are the ones the Lua 5.5 reference manual in `doc/`
//! states, cited where they are used. They are computed here in Zig rather than
//! run through the library and accepted, so a broken build cannot agree with
//! itself. The boundary facts are about this package's own choices: a
//! `State` that owns exactly one `lua_State`, an error object left exactly
//! where upstream left it, and a string that keeps every byte it was given.
//!
//! ## The allocator
//!
//! `luaL_newstate` allocates through libc's `realloc` and `free`
//! (`src/lauxlib.c:1062-1070`), not through `std.testing.allocator`. So
//! `testing.allocator` cannot be a leak oracle for anything Lua allocates, and
//! no test here claims it is. What a test can check is the ownership transition
//! this module owns: that `deinit` closes the state, that a second `deinit` on
//! the same variable is not a second close, and that one state closing does not
//! disturb another.
//!
//! One test supplies its own allocator and counts with it. A state opened
//! through `c.lua_newstate` with a counting `lua_Alloc` (`src/lua.h:163`) knows
//! exactly how many bytes upstream has asked for, and that is the only
//! independent way to check what the collector says it is holding. It
//! forwards to libc like `luaL_newstate` does, so it is still not a leak
//! oracle.

const std = @import("std");
const lua = @import("lua");
const testing = std.testing;

/// A shared object exporting the 157 declarations of `zig/translate.h`, named
/// by the environment in a runtime-loading build.
const provider_variable = "LUA_TEST_PROVIDER";

/// Make the native library usable, once, before a test calls the facade.
///
/// In a linked build the facade is usable already and this is a no-op at
/// comptime. In a runtime-loading build every call into the module goes through
/// a table that `load` fills, so this is where the one explicit load happens.
/// It is safe to call from every test: the contract makes the same request
/// idempotent, and the loader keeps the handle to the end of the process.
///
/// A build that was not told which file to load stops here with the variable's
/// name, rather than reporting a test failure that says nothing about the
/// reason. A suite that quietly stopped testing because a variable was unset
/// would report success for nothing.
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

/// Run `source` and take its single integer result, leaving the stack as it
/// was found.
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

/// Run `source` and take its single float result.
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

/// Run `source` and copy its single string result into `buffer`.
///
/// The copy is deliberate and is the only copy: Lua's own storage for the
/// result dies with the stack slot, and a test that compared against a pointer
/// into it would be comparing freed memory.
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

/// Run `source` and take its single boolean result.
///
/// `lua_toboolean` answers for any value - everything but `nil` and `false` is
/// true - so the type is checked first. Without that check a chunk that
/// returned a number would answer `true` here and this would report a value
/// the chunk never produced.
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

    // Integer arithmetic stays integer and wraps, which is a statement about
    // `lua_Integer` being 64 bits: 2^63 - 1 + 1 is 2^63 only as a wrap, not as
    // a value (`doc/manual.html`, 3.4.3 "Integer Arithmetic"). Comparing the
    // two leaves a Lua boolean on the stack, which `evalBool` reads as one.
    try testing.expectEqual(@as(i64, 42), try evalInt(&state, "return 6 * 7"));
    try testing.expectEqual(@as(i64, 3), try evalInt(&state, "return 7 // 2"));
    try testing.expectEqual(@as(i64, 1), try evalInt(&state, "return 7 % 2"));
    try testing.expect(try evalBool(&state, "return math.maxinteger + 1 == math.mininteger"));

    // `/` is always float, and `//` on a float operand truncates toward zero
    // and keeps a float result (3.4.3).
    try testing.expectApproxEqAbs(@as(f64, 0.5), try evalFloat(&state, "return 1 / 2"), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1024.0), try evalFloat(&state, "return 2 ^ 10"), 1e-9);
    try testing.expectApproxEqAbs(
        @as(f64, 3.0),
        try evalFloat(&state, "return 7 // 2.0"),
        1e-12,
    );

    // The two subtypes are distinct values, not one number type with two
    // spellings (3.4.3, `math.type`).
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

    // The length of a string is its byte count, not the distance to a NUL, so
    // a NUL in the middle is an ordinary byte (`doc/manual.html`, 3.1.1).
    try testing.expectEqual(
        @as(lua.Index, 3),
        try evalInt(&state, "return #\"a\\0b\""),
    );

    // The same three bytes through the C API, in both directions.
    const payload = [_]u8{ 'a', 0, 'b' };
    // `pushBytes` answers with the string it just pushed. A reader that took
    // its length from a NUL scan would answer one byte here, not three.
    try testing.expectEqualSlices(u8, &payload, state.pushBytes(&payload));
    try testing.expectEqual(@as(usize, 3), state.rawLength(-1));
    const read_back = state.toBytes(-1) orelse return error.NoString;
    try testing.expectEqualSlices(u8, &payload, read_back);

    // Round-tripping through Lua source preserves the embedded NUL too, which
    // is the property a C-string wrapper would lose.
    var buffer: [8]u8 = undefined;
    const text = try evalString(&state, "return \"a\\0b\"", &buffer);
    try testing.expectEqualSlices(u8, &payload, text);

    // A non-UTF-8 byte survives as well: 0xFF is not valid UTF-8 and Lua
    // neither rejects nor rewrites it.
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

    // Three values below everything the chunk does, so "the depth below did not
    // move" is a checkable claim rather than a hope.
    state.pushInteger(11);
    state.pushInteger(22);
    state.pushInteger(33);
    const depth_before = state.getTop();
    try testing.expectEqual(@as(lua.Index, 3), depth_before);

    // A runtime error: `error` with a string argument.
    try testing.expectError(error.RuntimeError, state.runChunk("error('boom')", "=demo"));
    try testing.expectEqual(depth_before + 1, state.getTop());
    try testing.expectEqual(lua.Type.string, state.typeOf(-1));

    var buffer: [256]u8 = undefined;
    const message = try state.takeError(&buffer);
    // The message carries the chunk name and the line, which is upstream's own
    // format (`src/ldo.c` prepends `chunkname:line:`).
    try testing.expect(std.mem.startsWith(u8, message, "demo:1: boom"));
    try testing.expectEqual(depth_before, state.getTop());
    try testing.expectEqual(@as(i64, 33), state.toInteger(-1) orelse return error.NoInteger);

    // A syntax error is a different status, and it leaves the compiler's own
    // message in the same place.
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

    // `error({})` leaves a table. Reading it as a string has to fail rather than
    // invent a text form, and `typeOf` has to say what is actually there.
    try testing.expectError(
        error.RuntimeError,
        state.runChunk("error({code = 7})", "=objects"),
    );
    try testing.expectEqual(lua.Type.table, state.typeOf(-1));
    try testing.expectEqual(@as(?[]const u8, null), state.errorMessage());
    try testing.expectEqualStrings("table", state.typeNameAt(-1) orelse return error.NoTypeName);
    state.discardError();

    // `error(42)` leaves a number. Reading it as a string goes through
    // `lua_tolstring`, which converts the slot in place; that is upstream's
    // documented behaviour (`src/lua.h:414-431`) and this module does not hide
    // it. `errorMessage` is the reader that leaves the value where it is, so
    // the conversion is observable on the stack before anything is taken.
    try testing.expectError(
        error.RuntimeError,
        state.runChunk("error(42)", "=numbers"),
    );
    try testing.expectEqual(lua.Type.number, state.typeOf(-1));
    try testing.expectEqualStrings("42", state.errorMessage() orelse return error.NoMessage);
    try testing.expectEqual(lua.Type.string, state.typeOf(-1));

    // `takeError` copies that same text and then removes the value, so the
    // stack is back exactly where the failed call found it.
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
    // `error('kept')` at a level raises a message with `luaL_where`'s
    // `chunkname:line: ` in front of the text (`src/lbaselib.c:116-125` into
    // `src/lauxlib.c:220-226`), so what is recorded here is the value itself -
    // what a `takeError` that could not take it has to leave untouched.
    const kept = state.errorMessage() orelse return error.NoMessage;
    const kept_address = state.toPointer(-1) orelse return error.NoPointer;

    // A buffer too small for the message is the caller's mistake, and the value
    // is still there afterwards: the caller can size a bigger buffer or read it
    // in place.
    var tiny: [2]u8 = undefined;
    try testing.expectError(
        error.ErrorBufferTooSmall,
        state.takeError(&tiny),
    );
    try testing.expectEqual(depth, state.getTop());
    try testing.expectEqual(lua.Type.string, state.typeOf(-1));
    try testing.expectEqual(kept_address, state.toPointer(-1) orelse return error.NoPointer);
    try testing.expectEqualStrings(kept, state.errorMessage() orelse return error.NoMessage);

    // A value with no string form cannot be taken at all, and says so.
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

    // The handler is below the function, so `pcall`'s argument count of zero
    // still points at the chunk and the error index points at the handler.
    state.pushCClosure(replaceMessage, 0);
    try testing.expectEqual(@as(lua.Index, 1), state.absIndex(-1));
    try state.load("error('original')", "=handled", null);
    const call_depth = state.getTop();
    try testing.expectError(error.RuntimeError, state.pcall(0, 0, 1));

    // A failed protected call restores the stack to where the function was
    // (`luaD_pcall` in `src/ldo.c:1083-1097` passes the function's own position
    // as the old top) and puts the error object in that slot, so the depth is
    // unchanged and only the value in it differs.
    try testing.expectEqual(call_depth, state.getTop());
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("replaced", try state.takeError(&buffer));

    // `takeError` removes the value it copied, so what is left is the handler
    // the failed call had restored underneath it, still at index 1: nothing
    // below the error object moved at any point.
    try testing.expectEqual(call_depth - 1, state.getTop());
    try testing.expectEqual(lua.Type.function, state.typeOf(1));
}

test "openLibraries is what puts the libraries in the globals table" {
    nativeReady();

    // A bare state has an empty globals table: nothing was opened, and a chunk
    // that reaches for `string` fails because of it. That is the difference
    // `init` and `initWithLibraries` make, and it is observable.
    var bare = try lua.State.init();
    defer bare.deinit();
    bare.getGlobal("string");
    try testing.expectEqual(lua.Type.nil, bare.typeOf(-1));
    try testing.expectError(
        error.RuntimeError,
        bare.runChunk("return string.format('%d', 1)", "=bare"),
    );
    bare.discardError();

    // With the libraries open, the same chunk produces its documented answer.
    var full = try lua.State.initWithLibraries();
    defer full.deinit();
    full.getGlobal("string");
    try testing.expectEqual(lua.Type.table, full.typeOf(-1));
    full.discardTop();
    // The chunk that raised on the bare state above produces its documented
    // answer here, which is the string `string.format` builds and not a
    // number: the length of a literal is a fact about the length operator and
    // says nothing about which libraries are open.
    var answer: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "1",
        try evalString(&full, "return string.format('%d', 1)", &answer),
    );

    // One library at a time, with nothing else dragged in.
    var one = try lua.State.init();
    defer one.deinit();
    one.openLibrary(.math);
    one.getGlobal("math");
    try testing.expectEqual(lua.Type.table, one.typeOf(-1));
    one.discardTop();
    one.getGlobal("string");
    try testing.expectEqual(lua.Type.nil, one.typeOf(-1));
    one.discardTop();

    // The documented behaviour of the string library, which is the oracle here
    // and not this package (`doc/manual.html`, 6.1).
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

    // A plain call across the boundary with a known answer.
    try testing.expectEqual(@as(i64, 21), try evalInt(&state, "return triple(7)"));

    // `explode` raises through `luaL_error`, which is a longjmp and not a
    // return. Called inside a protected call it must come back as an ordinary
    // error with the handler's text, and the stack below must be untouched.
    const before = state.getTop();
    try testing.expectError(
        error.RuntimeError,
        state.runChunk("return explode()", "=callback"),
    );
    try testing.expectEqual(before + 1, state.getTop());
    var buffer: [128]u8 = undefined;
    const message = try state.takeError(&buffer);
    try testing.expect(std.mem.startsWith(u8, message, "callback:1: exploded in C"));

    // And the state is still usable afterwards, which is the point of the
    // protected call: nothing was left half done.
    try testing.expectEqual(@as(i64, 21), try evalInt(&state, "return triple(7)"));
}

/// The message handler `pcall` is given. A C function like any other: it is
/// reached through the same boundary as `triple`, and it returns normally.
fn replaceMessage(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    const handle = state.?;
    _ = lua.c.lua_pushstring(handle, "replaced");
    return 1;
}

/// A callback with a known answer: three times its argument.
fn triple(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    const handle = state.?;
    // `luaL_checkinteger` raises through the same longjmp `luaL_error` does
    // (`src/lauxlib.h:62`), and it is correct here because `triple` only runs
    // inside a protected call that Lua made.
    const argument = lua.c.luaL_checkinteger(handle, 1);
    lua.c.lua_pushinteger(handle, argument * 3);
    return 1;
}

/// A callback that fails, to prove the longjmp boundary is where it is
/// documented to be.
fn explode(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    // `luaL_error` is a C variadic (`src/lauxlib.h:76`): promoted arguments in
    // a linked build, one trailing tuple through the runtime-loaded dispatch.
    // `lua.runtime_loaded` is comptime, so only the route this build has is
    // resolved, and both routes raise through the same longjmp.
    const handle = state.?;
    return if (comptime lua.runtime_loaded)
        lua.c.luaL_error(handle, "exploded in C", .{})
    else
        @call(.auto, lua.c.luaL_error, .{ handle, "exploded in C" });
}

/// What one `__gc` metamethod call recorded.
///
/// `fired` is what tells "the finalizer never ran" apart from "it ran and
/// upstream had no answer", which an optional on its own cannot.
const Observation = struct {
    fired: bool = false,
    answer: ?bool = null,
};

/// A `__gc` metamethod that records what `isCollecting` answers from inside a
/// finalizer.
///
/// The object it runs on carries the address of the caller's record - a
/// userdata holding one pointer, read back with `lua_touserdata` - so the
/// record lives in the test's own frame, two finalizers can be told apart, and
/// nothing is kept in a module-level variable where an untouched null would be
/// indistinguishable from a refusal.
fn recordCollection(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    const handle = state.?;
    const record: **Observation = @ptrCast(@alignCast(lua.c.lua_touserdata(handle, 1).?));
    // A view over the handle Lua is running this metamethod on, and nothing
    // more: it owns no state, so it must not be closed here.
    var observer = lua.State{ .raw = handle };
    record.*.answer = observer.isCollecting();
    record.*.fired = true;
    return 0;
}

/// Put one userdata on the stack whose `__gc` metamethod records into `record`,
/// which is what a collection or the state's own close will run.
fn armFinalizer(state: *lua.State, record: *Observation) void {
    _ = lua.c.lua_newuserdatauv(state.handle(), @sizeOf(*Observation), 0);
    const cell: **Observation = @ptrCast(@alignCast(lua.c.lua_touserdata(state.handle(), -1).?));
    cell.* = record;

    // Attaching the metamethod is what registers the object for finalizing
    // (`src/lgc.c:1068-1076`, reached from `lua_setmetatable`). Reaching it
    // afterwards is a second thing: a collection finalizes garbage, so the
    // caller collecting wants the object off the stack, while `lua_close` runs
    // every pending finalizer whatever their reachability
    // (`src/lgc.c:1529-1536`). That is why one test drops the stack and the
    // other does not.
    lua.c.lua_newtable(state.handle());
    lua.c.lua_pushcfunction(state.handle(), &recordCollection);
    lua.c.lua_setfield(state.handle(), -2, "__gc");
    _ = lua.c.lua_setmetatable(state.handle(), -2);
}

test "isCollecting answers upstream, and has no answer inside a finalizer" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // The three answers that are upstream's own. A collector that is neither
    // stopped nor closing answers one (`gcrunning(g)` is `gcstp == 0`,
    // `src/lgc.h:216`), a stop through this module sets the user's bit and
    // upstream answers zero (`src/lapi.c:1180-1182`), and a restart clears it
    // again. The middle one is the case that a refusal-aware accessor has to
    // keep distinct from having no answer at all.
    try testing.expectEqual(@as(?bool, true), state.isCollecting());
    state.stopGarbageCollector();
    try testing.expectEqual(@as(?bool, false), state.isCollecting());
    state.restartGarbageCollector();
    try testing.expectEqual(@as(?bool, true), state.isCollecting());

    // The window in which upstream has no answer at all: `lua_gc` refuses
    // every selector while the collector has stopped itself
    // (`src/lapi.c:1175-1176`), and `GCTM` sets exactly that stop for the
    // duration of a `__gc` metamethod (`src/lgc.c:968-987`).
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

    // `luaC_freeallobjects` sets the closing bit (`src/lgc.c:1531`) and then
    // runs every pending finalizer (`src/lgc.c:1535`), so a `__gc` that no
    // cycle has reached yet runs inside `lua_close` - still with nothing to
    // answer, and still recorded against the caller's own frame.
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

    // Build a batch of unreachable values in one call and return nothing, so
    // the whole batch is garbage the moment the call finishes.
    try state.load(build_garbage, "=garbage", null);
    try state.pcall(0, 0, 0);
    try testing.expectEqual(@as(lua.Index, 0), state.getTop());

    // Hold one reachable table across a full collection and check both that it
    // survived and that it is still the same table: `lua_topointer` is the
    // object address, so a value that had been rebuilt rather than kept would
    // answer differently here.
    state.newTable(0, 0);
    const kept = state.absIndex(-1);
    const kept_address = state.toPointer(kept) orelse return error.NoPointer;
    state.collectGarbage();
    try testing.expectEqual(
        kept_address,
        state.toPointer(kept) orelse return error.NoPointer,
    );

    // A value written into it before the second collection is still readable
    // after it.
    _ = state.pushBytes("still here");
    state.rawSetIndex(kept, 1);
    state.collectGarbage();
    state.rawGetIndex(kept, 1);
    try testing.expectEqualStrings("still here", state.toBytes(-1) orelse return error.NoBytes);
    state.discardTop();
    state.discardTop();

    // Stopping the collector, asking it for a cycle anyway, and restarting it
    // are three different selectors on the same variadic entry point, and the
    // state answers the same question afterwards either way.
    state.stopGarbageCollector();
    state.collectGarbage();
    state.restartGarbageCollector();
    state.collectGarbage();
    try testing.expectEqual(@as(i64, 2), try evalInt(&state, "return #({1, 2})"));
}

/// What the state has been handed, counted the way `src/lmem.c:26-42` says a
/// `lua_Alloc` is to read its two sizes: a new block is `nsize` whatever
/// `osize` says, because the tag upstream passes there is not a size
/// (`src/lstate.c:344-345`), a resize is `nsize - osize`, and a free is
/// `-osize`.
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

/// An allocator that counts and forwards to libc, which is the one every other
/// state in this file opens (`src/lauxlib.c:1062-1070`).
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

    // A state with a counting allocator behind it, which is what makes an
    // exact count possible: the bytes upstream asked for are the bytes it has.
    // `lua_newstate` takes that allocator and that pointer (`src/lua.h:163`),
    // and `State` is the struct that owns a handle, so `deinit` closes this one
    // exactly as it closes an opened one.
    var state: lua.State = .{
        .raw = lua.c.lua_newstate(countingAlloc, &counter, 0) orelse return error.NoState,
    };
    defer state.deinit();
    state.openLibraries();

    // Counted against a collector that cannot free anything. This is the user
    // stop (`src/lapi.c:1180-1182`), not the internal stop that makes every
    // selector answer -1 (`src/lapi.c:1175-1176`), so counting still answers.
    state.stopGarbageCollector();

    // Upstream splits this number into a kibibyte count and what is left over
    // below a kibibyte, so a total that happens to be a whole number of
    // kibibytes cannot tell the two apart. Each distinct length is a new
    // interned string, and so a new block, which is enough to leave a
    // remainder behind; asking again until it has one keeps that guarantee on
    // the number the assertions below use, since running the chunk allocates.
    var filler: [64]u8 = undefined;
    var length: usize = 0;
    var reported: f64 = 0;
    while (true) {
        // Lua's own answer for the same number, which is the independent
        // check: `collectgarbage("count")` is `LUA_GCCOUNT` plus
        // `LUA_GCCOUNTB` over 1024 (`src/lbaselib.c:210-215`), read after
        // every allocation the chunk itself made.
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

    // And the two accessors a consumer of this package reads: one is the count
    // above a kibibyte, the other is all of the bytes, remainder included.
    try testing.expectEqual(
        @as(c_int, @intCast(live >> 10)),
        state.garbageKilobytes().?,
    );
    try testing.expectEqual(live, state.garbageBytes().?);
}

// Each statement is separated: `end` and the next name would otherwise lex as
// one identifier and the loop would never be closed.
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

    // A negative index counts from the top; `absIndex` turns it into one
    // counted from the bottom, which is the only index that survives a call
    // that can move the stack (`doc/manual.html`, 4.1.2 "Valid and Acceptable
    // Indices", and 4.6 `lua_absindex`).
    try testing.expectEqual(@as(lua.Index, 1), state.absIndex(-3));
    try testing.expectEqual(@as(lua.Index, 3), state.absIndex(-1));
    try testing.expectEqual(@as(lua.Index, 3), state.getTop());

    // `checkStack` is how a C function asks for room; Lua guarantees
    // `LUA_MINSTACK` slots to one that has not asked
    // (`doc/manual.html`, 4.1.1 "Stack Size"; `src/lua.h:79`).
    try testing.expect(state.checkStack(@intCast(lua.min_stack + 1)));
    try testing.expectEqual(@as(lua.Index, 3), state.getTop());

    // `setTop` removes everything above a position.
    state.setTop(1);
    try testing.expectEqual(@as(lua.Index, 1), state.getTop());

    // Pushing a copy and comparing raw identity: the same table twice, one
    // address (`doc/manual.html`, 4.6 `lua_topointer`: different objects get
    // different pointers).
    state.getGlobal("string");
    const table_index = state.absIndex(-1);
    state.pushValue(table_index);
    try testing.expect(state.rawEqual(table_index, -1));
    state.discardTop();

    // `==` goes through a `__eq` metamethod; `rawequal` does not. Two tables
    // sharing one metatable are `==` and are not the same object, and the two
    // answers together say which path produced which.
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

    // The field is cleared, so closing again is not a second close. A state
    // whose handle were left in place would have been freed twice here.
    state.deinit();
    try testing.expect(!state.isOpen());

    // Two states are two owners of two states: closing one leaves the other
    // answering.
    var first = try lua.State.initWithLibraries();
    var second = try lua.State.initWithLibraries();
    try testing.expectEqual(@as(i64, 1), try evalInt(&first, "return 1"));
    first.deinit();
    try testing.expect(!first.isOpen());
    try testing.expectEqual(@as(i64, 2), try evalInt(&second, "return 2"));
    second.deinit();

    // And a fresh state starts from nothing: globals set in a closed state do
    // not survive into the next one.
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

    // `newThread` pushes what it created, and what it pushed is a thread. The
    // view and its anchor share a scope: popping the thread removes the only
    // root the collector can see, so the non-owning handle must not outlive
    // it, and the checks that use it all happen inside.
    {
        const thread = state.newThread();
        try testing.expectEqual(lua.Type.thread, state.typeOf(-1));

        // The value read back out of the stack is the same thread, not a second
        // one: a facade that had rebuilt a handle instead of handing the
        // thread's own would give a different `handle()` here.
        const from_stack = state.toThread(-1) orelse return error.NotAThread;
        try testing.expectEqual(thread.handle(), from_stack.handle());
        state.discardTop();
    }

    var buffer: [64]u8 = undefined;

    // Resuming one built from Lua is the documented way to see the result cross
    // back (`doc/manual.html`, 2.6 "Coroutines").
    try testing.expectEqualStrings(
        "42",
        try evalString(&state, resume_multiplier, &buffer),
    );

    // A failure inside the coroutine comes back as a failed resume rather than
    // as a value, and what it carries is the error object the body raised with
    // `luaL_where`'s `chunkname:line: ` in front of it. Which chunk that names
    // and which line it sits on are this file's own naming and layout, so the
    // message is checked by what it ends with - the position separator and the
    // text the body raised - and the resume status is read as the boolean it is.
    const failure = try evalString(&state, resume_failure, &buffer);
    try testing.expect(std.mem.endsWith(u8, failure, ": inside"));
    try testing.expect(!try evalBool(&state, resume_failure_status));

    // A coroutine that yields is resumable again, and the two resumptions give
    // the two values it produced (`doc/manual.html`, 2.6, `coroutine.wrap`).
    try testing.expectEqualStrings(
        "1 2",
        try evalString(&state, resume_yield_twice, &buffer),
    );
}

/// A coroutine body with a known answer: twice its argument.
fn doubleArgument(state: ?*lua.c.lua_State) callconv(.c) lua.Index {
    const handle = state.?;
    lua.c.lua_pushinteger(handle, lua.c.luaL_checkinteger(handle, 1) * 2);
    return 1;
}

test "resuming a coroutine reports what it left on its own stack" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // The thread is anchored on the parent's stack and the view is
    // non-owning, so nothing here closes it: the state does.
    const runner = state.newThread();
    lua.c.lua_pushcclosure(runner.handle(), doubleArgument, 0);
    lua.c.lua_pushinteger(runner.handle(), 21);

    // 21 * 2 is 42, and the multiplication happened inside the coroutine.
    const produced = try runner.@"resume"(1);
    try testing.expectEqual(@as(usize, 1), produced);

    // The values are on the coroutine's own stack. `lua_xmove` through the raw
    // route brings them back, which is what `coroutine.resume` does upstream
    // (`src/lcorolib.c:43` resumes, `src/lcorolib.c:52-53` moves the results
    // across): a `ThreadRef` is not a `State`, so it cannot be an endpoint of
    // `State.move`.
    lua.c.lua_xmove(runner.handle(), state.handle(), 1);
    try testing.expectEqual(@as(i64, 42), state.toInteger(-1) orelse return error.NoInteger);
    state.discardTop();
    state.discardTop();
}

test "statusOf reads the status upstream leaves on a thread" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // The main thread is `LUA_OK` - `stack_init` writes it
    // (`src/lstate.c:158`) and a call that completes leaves it there - so the
    // answer a caller most needs to trust as "not a failure" is one this
    // actually gives rather than one it infers from the absence of an error.
    try testing.expectEqual(lua.Status.ok, try state.statusOf());
    try state.runChunk("return 6 * 7", "=status");
    try testing.expectEqual(lua.Status.ok, try state.statusOf());

    // A thread that has yielded is suspended, and upstream leaves it in
    // `LUA_YIELD` until it is resumed (`src/ldo.c:1021`). The resume itself
    // fails, because from the resumer's side a yield and a failure are one
    // thing; the status is where the two are told apart.

    // `runner_view` is a view over that thread and not a second owner of it:
    // `statusOf` is a `State` method and a `ThreadRef` is not a `State`, so
    // this is how a caller reads one. It is never closed - the thread belongs
    // to `state`, which still has it anchored on that stack.
    const runner = state.newThread();
    var runner_view = lua.State{ .raw = runner.handle() };
    try runner_view.loadChunk("coroutine.yield(1)", "=yielding");
    try testing.expectError(error.RuntimeError, runner.@"resume"(0));
    try testing.expectEqual(lua.Status.yield, try runner_view.statusOf());

    // Resumed again, the body runs to its end and the thread is normal: the
    // chunk yields a value the first time and returns nothing the second, so
    // the resume that finishes it produces no value at all.
    try testing.expectEqual(@as(usize, 0), try runner.@"resume"(0));
    try testing.expectEqual(lua.Status.ok, try runner_view.statusOf());

    // A body that raised leaves the code it stopped on - `lua_resume` marks the
    // thread dead with it (`src/ldo.c:992`) - so the status names which failure
    // it was instead of reporting that something went wrong.
    try runner_view.loadChunk("error('inside')", "=failing");
    try testing.expectError(error.RuntimeError, runner.@"resume"(0));
    try testing.expectEqual(lua.Status.runtime, try runner_view.statusOf());

    // What this test deliberately does not reach is `error.UnexpectedStatus`.
    // No valid provider can produce it, and a test that reached it would have
    // to supply a native library that lies about `lua_status`, which is a
    // fixture rather than a fact. `lua_status` is `L->status` and nothing else
    // (`src/lapi.c:1163-1165`), every write to that field is one of the seven
    // codes `lua.Status` names, and upstream's manual says the same in prose:
    // "The status can be `LUA_OK` for a normal thread, an error code if the
    // thread finished the execution of a `lua_resume` with an error, or
    // `LUA_YIELD` if the thread is suspended" (`doc/manual.html:5793-5801`).
}

const resume_multiplier =
    "local co = coroutine.create(function(a, b) return a * b end)" ++
    "local ok, value = coroutine.resume(co, 6, 7)" ++
    "return tostring(value)";

/// The message a resume reports for a body that raised, which upstream prefixes
/// with the position (`src/lauxlib.c:220-226`); only its tail is asserted.
const resume_failure =
    "local co = coroutine.create(function() error('inside') end)" ++
    "local ok, message = coroutine.resume(co)" ++
    "return message";

/// Whether the resume failed rather than returned a value, which is the
/// distinction the coroutine library draws.
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

    // `lua_pushfstring` is a real C variadic, reached here through the raw
    // route. Its trailing arguments are promoted in a linked build and arrive
    // as one tuple through the runtime-loaded dispatch; `lua.runtime_loaded`
    // is comptime, so only the route this build has is resolved. Reading the
    // result back through the facade is what shows the two routes are the same
    // library.
    const format = "%s=%d";
    const arguments = .{ "n", @as(lua.Index, 7) };
    _ = if (comptime lua.runtime_loaded)
        lua.c.lua_pushfstring(state.handle(), format, arguments)
    else
        @call(.auto, lua.c.lua_pushfstring, .{ state.handle(), format } ++ arguments);
    try testing.expectEqualStrings("n=7", state.toBytes(-1) orelse return error.NoString);
    state.discardTop();

    // `luaL_len` is an entry point this facade does not wrap. It is on a table
    // of three array items and answers with the array length.
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

    // `lua_pushlstring` and `lua_tolstring` are the same two entry points
    // `pushBytes` and `toBytes` wrap, reached directly.
    const payload = [_]u8{ 0x00, 0x7F, 0x80, 0xFF };
    _ = lua.c.lua_pushlstring(state.handle(), &payload, payload.len);
    var length: usize = 0;
    const text = lua.c.lua_tolstring(state.handle(), -1, &length);
    try testing.expectEqual(payload.len, length);
    try testing.expectEqualSlices(u8, &payload, text[0..length]);
    state.discardTop();

    // `lua_ident` is the one exported data object, and this package reads it
    // through the same module in either configuration. It is the provider's own
    // banner, so it says which release answered - `LUA_COPYRIGHT` embeds
    // `LUA_RELEASE`, which is `Lua 5.5.1` (`src/lua.h:16,515-520`) - and a
    // provider from another family would say that family's version instead. A
    // bare "Lua" would pass for every family; the release built here does not.
    const ident = lua.version_ident();
    try testing.expect(ident.len > 0);
    var banner: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&banner, "Lua {d}.{d}.{d}", .{
        @as(u32, @intCast(lua.version_num / 100)),
        @as(u32, @intCast(lua.version_num % 100)),
        // `version_release_num` is `version_num * 100 + release`
        // (`src/lua.h:24-25`), so the release is what is left after removing
        // that part.
        @as(u32, @intCast(lua.version_release_num - lua.version_num * 100)),
    });
    try testing.expect(std.mem.indexOf(u8, ident, expected) != null);
}

test "the numeric type boundary is observable, not assumed" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // An integer with no exact float spelling is kept exactly by the integer
    // reader, while the float reader rounds it to a representable value, which
    // never fails (`doc/manual.html`, 3.4.3).
    state.pushInteger(9007199254740993);
    try testing.expectEqual(@as(i64, 9007199254740993), state.toInteger(-1) orelse return error.NoInteger);
    // `toNumber` does convert an integer to its float value, which is why it
    // answers 2^53 rather than the original integer.
    const as_float = state.toNumber(-1) orelse return error.NoNumber;
    try testing.expectApproxEqAbs(@as(f64, 9007199254740992.0), as_float, 1.0);
    state.discardTop();

    // A string with no numeric value is not a number at all.
    _ = state.pushBytes("not a number");
    try testing.expectEqual(@as(?f64, null), state.toNumber(-1));
    try testing.expectEqual(@as(?i64, null), state.toInteger(-1));
    state.discardTop();

    // `lua_Unsigned` is unsigned, so the wrap is in the other direction too.
    try testing.expect(try evalBool(&state, "return math.mininteger - 1 == math.maxinteger"));
}

test "stack values keep their identity through push and get" {
    nativeReady();
    var state = try lua.State.initWithLibraries();
    defer state.deinit();

    // One table, two stack slots, one address: `lua_topointer` is the identity
    // a C caller compares, and a facade that rebuilt a value instead of
    // pushing it would give two addresses.
    state.newTable(0, 0);
    const first = state.absIndex(-1);
    state.pushValue(first);
    const second = state.absIndex(-1);
    try testing.expectEqual(
        state.toPointer(first) orelse return error.NoPointer,
        state.toPointer(second) orelse return error.NoPointer,
    );

    // Two separately created tables are two addresses.
    state.newTable(0, 0);
    const third = state.absIndex(-1);
    try testing.expect(state.toPointer(first) != state.toPointer(third));

    // Reading the top as bytes is not possible for a table, and the type is
    // still a table afterwards: the failed read changed nothing.
    try testing.expectEqual(@as(?[]const u8, null), state.toBytes(third));
    try testing.expectEqual(lua.Type.table, state.typeOf(third));
}