// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! Zig facade over Lua's C API, with an owning `State` and typed status errors.
//! `State` owns one Lua state; `ThreadRef` borrows its coroutine.
//! Returned strings borrow Lua storage; strings remain length-counted bytes.
//! Runtime-loaded builds require an explicit provider and cannot unload or fall back.
//! Protected failures leave the Lua error object on the stack; longjmps do not unwind Zig defers.
//! Calls on each `lua_State` must be serialized by the caller.
const std = @import("std");

/// Translated Lua headers expose upstream declarations, constants, and macros through this module.
/// Raw calls retain Lua's ABI, including C variadics and longjmp behavior.
pub const c = @import("c");

/// Loader types for linked builds; runtime mode uses the dispatch's equivalent types.
const rt = @import("rt");

/// Whether this build resolves native symbols at runtime; comptime for route selection.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Explicit provider file or system-library name; requests never fall back between them.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Errors returned when a runtime provider cannot be loaded.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load an explicit runtime provider; repeated identical requests are idempotent.
/// Different requests return `ProviderMismatch`; linked builds panic, and providers stay loaded.
pub fn load(source: LoadSource) LoadError!void {
    // Keep runtime-only declarations behind a comptime condition.
    if (runtime_loaded) return c.load(source);
    std.debug.panic(
        "lua: load was called on a linked build; this module is not " ++
            "runtime-loaded, so there is no library to load. Build with " ++
            "runtime loading configured, or do not call load.",
        .{},
    );
}

/// The successful provider request, borrowed for process lifetime; null in linked builds.
pub fn loadedSource() ?LoadSource {
    if (runtime_loaded) return c.loadedSource();
    return null;
}

/// Lua stack index: 1 is bottom, -1 is top, and pseudo-indices are negative.
pub const Index = c_int;

/// Lua API version number: major times 100 plus minor.
pub const version_num: i32 = c.LUA_VERSION_NUM;

/// Lua release number: `version_num * 100 + release`.
pub const version_release_num: i32 = c.LUA_VERSION_RELEASE_NUM;

/// Signature prefix of precompiled Lua chunks; `lua_load` rejects other prefixes.
pub const signature: [:0]const u8 = c.LUA_SIGNATURE;

/// Pseudo-index of Lua's registry.
pub const registry_index: Index = c.LUA_REGISTRYINDEX;

/// Pseudo-index for upvalue `n`.
pub fn upvalue_index(n: Index) Index {
    return registry_index - n;
}

/// Minimum stack slots available to a C function before it requests more.
pub const min_stack: usize = c.LUA_MINSTACK;

/// Pass as `nresults` to retain all call results.
pub const multret: Index = c.LUA_MULTRET;

/// Provider's NUL-terminated copyright banner; runtime mode borrows provider storage.
pub fn version_ident() [:0]const u8 {
    if (comptime runtime_loaded) return std.mem.span(c.lua_identAddr());
    return std.mem.span(c.lua_ident);
}

/// Lua standard libraries and their upstream names, openers, and mask bits.
pub const Library = enum {
    base,
    package,
    coroutine,
    debug,
    io,
    math,
    os,
    string,
    table,
    utf8,

    /// The global name bound to this library.
    pub fn name(lib: Library) [:0]const u8 {
        return switch (lib) {
            .base => c.LUA_GNAME,
            .package => c.LUA_LOADLIBNAME,
            .coroutine => c.LUA_COLIBNAME,
            .debug => c.LUA_DBLIBNAME,
            .io => c.LUA_IOLIBNAME,
            .math => c.LUA_MATHLIBNAME,
            .os => c.LUA_OSLIBNAME,
            .string => c.LUA_STRLIBNAME,
            .table => c.LUA_TABLIBNAME,
            .utf8 => c.LUA_UTF8LIBNAME,
        };
    }

    /// This library's C opener function.
    pub fn opener(lib: Library) CFunction {
        return switch (lib) {
            .base => c.luaopen_base,
            .package => c.luaopen_package,
            .coroutine => c.luaopen_coroutine,
            .debug => c.luaopen_debug,
            .io => c.luaopen_io,
            .math => c.luaopen_math,
            .os => c.luaopen_os,
            .string => c.luaopen_string,
            .table => c.luaopen_table,
            .utf8 => c.luaopen_utf8,
        };
    }

    /// This library's bit in `luaL_openselectedlibs`' mask.
    pub fn mask(lib: Library) c_int {
        return switch (lib) {
            .base => c.LUA_GLIBK,
            .package => c.LUA_LOADLIBK,
            .coroutine => c.LUA_COLIBK,
            .debug => c.LUA_DBLIBK,
            .io => c.LUA_IOLIBK,
            .math => c.LUA_MATHLIBK,
            .os => c.LUA_OSLIBK,
            .string => c.LUA_STRLIBK,
            .table => c.LUA_TABLIBK,
            .utf8 => c.LUA_UTF8LIBK,
        };
    }
};

/// Lua value types; `none` means the stack index does not exist.
pub const Type = enum(c_int) {
    none = c.LUA_TNONE,
    nil = c.LUA_TNIL,
    boolean = c.LUA_TBOOLEAN,
    lightuserdata = c.LUA_TLIGHTUSERDATA,
    number = c.LUA_TNUMBER,
    string = c.LUA_TSTRING,
    table = c.LUA_TTABLE,
    function = c.LUA_TFUNCTION,
    userdata = c.LUA_TUSERDATA,
    thread = c.LUA_TTHREAD,
};

/// Comparison operators for `State.compare`; metamethods are included.
pub const CompareOp = enum(c_int) {
    eq = c.LUA_OPEQ,
    lt = c.LUA_OPLT,
    le = c.LUA_OPLE,
};

/// Arithmetic and bitwise operations for `State.arith`.
/// Binary operations use the second stack value as the left operand.
pub const ArithOp = enum(c_int) {
    add = c.LUA_OPADD,
    sub = c.LUA_OPSUB,
    mul = c.LUA_OPMUL,
    mod = c.LUA_OPMOD,
    pow = c.LUA_OPPOW,
    div = c.LUA_OPDIV,
    idiv = c.LUA_OPIDIV,
    band = c.LUA_OPBAND,
    bor = c.LUA_OPBOR,
    bxor = c.LUA_OPBXOR,
    shl = c.LUA_OPSHL,
    shr = c.LUA_OPSHR,
    unm = c.LUA_OPUNM,
    bnot = c.LUA_OPBNOT,
};

/// Lua status errors returned by loads, protected calls, resumes, and status queries.
/// `UnexpectedStatus` covers unknown codes; `FileError` is reachable only through raw `c`.
pub const Error = error{
    /// `LUA_ERRSYNTAX`: the chunk did not compile.
    SyntaxError,
    /// `LUA_ERRMEM`: memory for the operation could not be obtained.
    MemoryError,
    /// `LUA_ERRRUN`: the chunk, or something it called, raised an error.
    RuntimeError,
    /// `LUA_ERRERR`: the error handler itself raised an error.
    ErrorInErrorHandler,
    /// File error from raw `c.luaL_loadfilex`; no typed facade call produces it.
    FileError,
    /// A status code with no corresponding error tag.
    UnexpectedStatus,
};

/// C callback type; longjmp-capable helpers must run inside a protected Lua call.
pub const CFunction = c.lua_CFunction;

/// Owns one `lua_State`; `deinit` closes it, and copying `State` duplicates ownership.
pub const State = struct {
    /// Owned Lua state, or null after `deinit`.
    raw: ?*c.lua_State = null,

    /// State creation can fail when Lua cannot allocate memory.
    pub const InitError = error{OutOfMemory};

    /// Create a state without standard libraries; returns `OutOfMemory` on failure.
    pub fn init() InitError!State {
        const raw = c.luaL_newstate() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// Create a state with all standard libraries loaded.
    pub fn initWithLibraries() InitError!State {
        var self = try init();
        self.openLibraries();
        return self;
    }

    /// Close this state's Lua state through its creating provider, then clear the handle.
    /// Repeated calls are no-ops.
    pub fn deinit(self: *State) void {
        const raw = self.raw orelse return;
        self.raw = null;
        c.lua_close(raw);
    }

    /// Whether this state still owns an open Lua state.
    pub fn isOpen(self: *const State) bool {
        return self.raw != null;
    }

    /// Return the raw handle for unwrapped APIs; panic if the state is closed.
    pub fn handle(self: *const State) *c.lua_State {
        return self.raw orelse @panic(
            "lua: this State was closed; deinit() clears the handle and there is " ++
                "no state left to call. Check isOpen() if the lifetime is not " ++
                "obvious.",
        );
    }

    /// Load all standard libraries into the globals table.
    pub fn openLibraries(self: *State) void {
        c.luaL_openselectedlibs(self.handle(), -1, 0);
    }

    /// Load libraries selected by `mask`; nonzero `preload` registers them for `require`.
    pub fn openSelectedLibraries(self: *State, mask: c_int, preload: c_int) void {
        c.luaL_openselectedlibs(self.handle(), mask, preload);
    }

    /// Load one standard library and leave the stack unchanged.
    pub fn openLibrary(self: *State, lib: Library) void {
        const state = self.handle();
        c.luaL_requiref(state, lib.name(), lib.opener(), 1);
        self.discardTop();
    }

    /// Push the globals table.
    pub fn pushGlobals(self: *State) void {
        c.lua_rawgeti(self.handle(), registry_index, c.LUA_RIDX_GLOBALS);
    }

    /// The index of the top element, so zero for an empty stack.
    pub fn getTop(self: *const State) Index {
        return c.lua_gettop(self.handle());
    }

    /// Set the stack top; negative indices count from the current top.
    pub fn setTop(self: *State, index: Index) void {
        c.lua_settop(self.handle(), index);
    }

    /// Remove the value at the top of the stack.
    pub fn discardTop(self: *State) void {
        c.lua_settop(self.handle(), -2);
    }

    /// Reserve `n` more stack slots; existing values may move, so rebase indices.
    pub fn checkStack(self: *State, n: Index) bool {
        return c.lua_checkstack(self.handle(), n) != 0;
    }

    /// Turn a possibly-relative index into one counted from the bottom.
    pub fn absIndex(self: *const State, index: Index) Index {
        return c.lua_absindex(self.handle(), index);
    }

    /// Push a copy of the value at `index`.
    pub fn pushValue(self: *State, index: Index) void {
        c.lua_pushvalue(self.handle(), index);
    }

    /// Rotate values from `index`; `insertTop` is `rotate(index, 1)`.
    pub fn rotate(self: *State, index: Index, n: Index) void {
        c.lua_rotate(self.handle(), index, n);
    }

    /// Insert the value on top of the stack at `index`.
    pub fn insertTop(self: *State, index: Index) void {
        self.rotate(index, 1);
    }

    /// Copy the value at `from` over `to`, keeping both slots.
    pub fn copy(self: *State, from: Index, to: Index) void {
        c.lua_copy(self.handle(), from, to);
    }

    /// Move `n` values from this state's stack to another state's stack.
    pub fn move(self: *State, to: *const State, n: Index) void {
        c.lua_xmove(self.handle(), to.handle(), n);
    }

    /// Push nil; `Type.none` still means the stack index does not exist.
    pub fn pushNil(self: *State) void {
        c.lua_pushnil(self.handle());
    }

    /// Push a Lua boolean.
    pub fn pushBoolean(self: *State, value: bool) void {
        c.lua_pushboolean(self.handle(), @intFromBool(value));
    }

    /// Push a Lua 64-bit integer.
    pub fn pushInteger(self: *State, value: i64) void {
        c.lua_pushinteger(self.handle(), value);
    }

    /// Push a Lua double.
    pub fn pushNumber(self: *State, value: f64) void {
        c.lua_pushnumber(self.handle(), value);
    }

    /// Push length-counted bytes, including NUL; returns a slice owned by Lua.
    /// The borrowed slice may expire when its stack value is collected.
    pub fn pushBytes(self: *State, bytes: []const u8) []const u8 {
        const text = c.lua_pushlstring(self.handle(), bytes.ptr, bytes.len);
        return text[0..bytes.len];
    }

    /// Push an address-keyed value that Lua does not collect.
    pub fn pushLightUserdata(self: *State, pointer: ?*anyopaque) void {
        c.lua_pushlightuserdata(self.handle(), pointer);
    }

    /// Allocate zeroed collector-owned userdata with `userValues` and return its pointer.
    /// The pointer is borrowed and may become invalid after collection.
    pub fn newUserdata(self: *State, size: usize, userValues: Index) ?*anyopaque {
        return c.lua_newuserdatauv(self.handle(), size, userValues);
    }

    /// Return the value type at `index`, or `Type.none` when it does not exist.
    pub fn typeOf(self: *const State, index: Index) Type {
        return @fromBackingInt(@intCast(c.lua_type(self.handle(), index)));
    }

    /// Return the upstream name for a type, or null for an unknown type code.
    pub fn typeNameOf(self: *State, type_code: Type) ?[:0]const u8 {
        const text = c.lua_typename(self.handle(), @backingInt(type_code));
        if (text == null) return null;
        return std.mem.span(text);
    }

    /// Return the upstream name for the value at `index`.
    pub fn typeNameAt(self: *State, index: Index) ?[:0]const u8 {
        return self.typeNameOf(self.typeOf(index));
    }

    /// Return an exact integer, or null; this conversion does not change the stack.
    pub fn toInteger(self: *const State, index: Index) ?i64 {
        var is_number: c_int = 0;
        const value = c.lua_tointegerx(self.handle(), index, &is_number);
        if (is_number == 0) return null;
        return value;
    }

    /// Convert the value at `index` to a number, or return null when conversion fails.
    pub fn toNumber(self: *const State, index: Index) ?f64 {
        var is_number: c_int = 0;
        const value = c.lua_tonumberx(self.handle(), index, &is_number);
        if (is_number == 0) return null;
        return value;
    }

    /// The truthiness of a value, which is `false` only for `nil` and `false`.
    pub fn toBoolean(self: *const State, index: Index) bool {
        return c.lua_toboolean(self.handle(), index) != 0;
    }

    /// Return length-counted bytes borrowed from Lua until the slot changes or is collected.
    /// Numeric values convert to strings in place; values without a string form return null.
    pub fn toBytes(self: *State, index: Index) ?[]const u8 {
        var length: usize = 0;
        const text = c.lua_tolstring(self.handle(), index, &length);
        if (text == null) return null;
        return text[0..length];
    }

    /// Return the raw length of a string, table, or userdata without conversion.
    pub fn rawLength(self: *const State, index: Index) usize {
        const length = c.lua_rawlen(self.handle(), index);
        return std.math.cast(usize, length) orelse std.math.maxInt(usize);
    }

    /// Return an identity pointer for the value; numeric pseudo-addresses must not be dereferenced.
    pub fn toPointer(self: *const State, index: Index) ?*const anyopaque {
        return c.lua_topointer(self.handle(), index);
    }

    /// Return the C function at `index`, or null for another value type.
    pub fn toCFunction(self: *const State, index: Index) ?CFunction {
        return c.lua_tocfunction(self.handle(), index);
    }

    /// Return a borrowed thread view for the value at `index`, or null.
    pub fn toThread(self: *const State, index: Index) ?ThreadRef {
        const raw = c.lua_tothread(self.handle(), index) orelse return null;
        return .{ .raw = raw };
    }

    /// Push a new table with array and record capacity hints.
    pub fn newTable(self: *State, array_hint: Index, record_hint: Index) void {
        c.lua_createtable(self.handle(), array_hint, record_hint);
    }

    /// Push the value of the global `name`.
    pub fn getGlobal(self: *State, name: [:0]const u8) void {
        _ = c.lua_getglobal(self.handle(), name);
    }

    /// Pop the value on top into the global `name`.
    pub fn setGlobal(self: *State, name: [:0]const u8) void {
        c.lua_setglobal(self.handle(), name);
    }

    /// Push `table[key]`, applying metamethods.
    pub fn getField(self: *State, index: Index, key: [:0]const u8) void {
        _ = c.lua_getfield(self.handle(), index, key);
    }

    /// Pop the top value into `table[key]`, applying metamethods.
    pub fn setField(self: *State, index: Index, key: [:0]const u8) void {
        c.lua_setfield(self.handle(), index, key);
    }

    /// Push `table[n]`, applying metamethods.
    pub fn getIndex(self: *State, index: Index, key: i64) void {
        _ = c.lua_geti(self.handle(), index, key);
    }

    /// Pop the top value into `table[n]`, applying metamethods.
    pub fn setIndex(self: *State, index: Index, key: i64) void {
        c.lua_seti(self.handle(), index, key);
    }

    /// Push `table[n]` without applying metamethods.
    pub fn rawGetIndex(self: *State, index: Index, key: i64) void {
        _ = c.lua_rawgeti(self.handle(), index, key);
    }

    /// Pop the top value into `table[n]` without applying metamethods.
    pub fn rawSetIndex(self: *State, index: Index, key: i64) void {
        c.lua_rawseti(self.handle(), index, key);
    }

    /// Compare values by identity or primitive equality, ignoring metamethods.
    pub fn rawEqual(self: *const State, a: Index, b: Index) bool {
        return c.lua_rawequal(self.handle(), a, b) != 0;
    }

    /// Compare values with Lua's `==`, `<`, or `<=` semantics, including metamethods.
    pub fn compare(self: *const State, a: Index, b: Index, op: CompareOp) bool {
        return c.lua_compare(self.handle(), a, b, @backingInt(op)) != 0;
    }

    /// Perform an arithmetic or bitwise operation on the stack values.
    pub fn arith(self: *State, op: ArithOp) void {
        c.lua_arith(self.handle(), @backingInt(op));
    }

    /// Concatenate the top `n` values from left to right.
    pub fn concat(self: *State, n: Index) void {
        c.lua_concat(self.handle(), n);
    }

    /// Replace the value at `index` with its length, applying `__len` if present.
    pub fn lengthOf(self: *State, index: Index) void {
        c.lua_len(self.handle(), index);
    }

    /// Compile and push `source`; `chunk_name` labels errors and `mode` selects text or binary.
    /// Syntax and memory errors leave the error object on top.
    pub fn load(
        self: *State,
        source: []const u8,
        chunk_name: ?[:0]const u8,
        mode: ?[:0]const u8,
    ) Error!void {
        // Pass absent chunk name and mode as null so Lua applies its defaults.
        const status = c.luaL_loadbufferx(
            self.handle(),
            source.ptr,
            source.len,
            if (chunk_name) |name| name.ptr else null,
            if (mode) |accepted| accepted.ptr else null,
        );
        try statusOk(status);
    }

    /// Compile `source` with a literal chunk name.
    pub fn loadChunk(self: *State, source: []const u8, chunk_name: [:0]const u8) Error!void {
        return self.load(source, chunk_name, null);
    }

    /// Call the stack function without protection; Lua errors longjmp past Zig defers.
    pub fn call(self: *State, nargs: Index, nresults: Index) void {
        c.lua_callk(self.handle(), nargs, nresults, 0, null);
    }

    /// Call the stack function protected; failure leaves the error object on top.
    /// `nargs`, `nresults`, and `error_func` select arguments, results, and an optional handler.
    pub fn pcall(self: *State, nargs: Index, nresults: Index, error_func: Index) Error!void {
        const status = c.lua_pcallk(self.handle(), nargs, nresults, error_func, 0, null);
        try statusOk(status);
    }

    /// Compile and run source without arguments or results; failures leave the error object on top.
    pub fn runChunk(self: *State, source: []const u8, chunk_name: [:0]const u8) Error!void {
        try self.load(source, chunk_name, null);
        try self.pcall(0, 0, 0);
    }

    /// Return the top error as borrowed bytes without removing it, or null if it has no string form.
    /// The slice remains valid until the stack slot changes or Lua collects it.
    pub fn errorMessage(self: *State) ?[]const u8 {
        return self.toBytes(-1);
    }

    /// Copy the top error into caller-owned `buffer` and remove it on success.
    /// `TakeError` failures leave the stack value untouched.
    pub fn takeError(self: *State, buffer: []u8) TakeError![]const u8 {
        const message = self.toBytes(-1) orelse return error.NoErrorMessage;
        if (message.len > buffer.len) return error.ErrorBufferTooSmall;
        @memcpy(buffer[0..message.len], message);
        self.discardTop();
        return buffer[0..message.len];
    }

    /// Errors from copying the top stack value into a caller-owned buffer.
    /// Both errors leave the original value on the stack.
    pub const TakeError = error{
        /// The value on top has no string form.
        NoErrorMessage,
        /// The buffer is too small; the error object remains on the stack.
        ErrorBufferTooSmall,
    };

    /// Remove the error object at the top of the stack.
    pub fn discardError(self: *State) void {
        self.discardTop();
    }

    /// Push a C function with the top `upvalues` values captured.
    pub fn pushCClosure(self: *State, function: CFunction, upvalues: Index) void {
        c.lua_pushcclosure(self.handle(), function, upvalues);
    }

    /// Register a C callback as a global; longjmp-capable helpers require a protected Lua call.
    pub fn register(self: *State, name: [:0]const u8, function: CFunction) void {
        self.pushCClosure(function, 0);
        self.setGlobal(name);
    }

    /// Register functions from a zero-terminated `luaL_Reg` array.
    pub fn setFunctions(self: *State, entries: []const Reg) void {
        c.luaL_setfuncs(self.handle(), entries.ptr, 0);
    }

    /// Upstream `luaL_Reg` entry type; a zeroed record terminates the array.
    pub const Reg = c.luaL_Reg;

    /// Run one full garbage-collection cycle.
    pub fn collectGarbage(self: *State) void {
        _ = callGc(self.handle(), c.LUA_GCCOLLECT, .{});
    }

    /// Stop automatic collection without changing the stack.
    /// Call `restartGarbageCollector` to resume collection.
    pub fn stopGarbageCollector(self: *State) void {
        _ = callGc(self.handle(), c.LUA_GCSTOP, .{});
    }

    /// Restart the collector; this resets its schedule but does not run a cycle.
    pub fn restartGarbageCollector(self: *State) void {
        _ = callGc(self.handle(), c.LUA_GCRESTART, .{});
    }

    /// Whether collection is running; false after an explicit stop, null if Lua refuses the query.
    pub fn isCollecting(self: *State) ?bool {
        const running = counted(callGc(self.handle(), c.LUA_GCISRUNNING, .{})) orelse return null;
        return running != 0;
    }

    /// Return managed memory in kibibytes, or null when Lua refuses the selector.
    pub fn garbageKilobytes(self: *State) ?c_int {
        return counted(callGc(self.handle(), c.LUA_GCCOUNT, .{}));
    }

    /// Return managed memory in bytes from the kilobyte count and remainder, or null on refusal.
    pub fn garbageBytes(self: *State) ?usize {
        const state = self.handle();
        const kibibytes = counted(callGc(state, c.LUA_GCCOUNT, .{})) orelse return null;
        const remainder = counted(callGc(state, c.LUA_GCCOUNTB, .{})) orelse return null;
        return @as(usize, @intCast(kibibytes)) * 1024 + @as(usize, @intCast(remainder));
    }

    /// Run one collection step and return whether it completed a cycle.
    pub fn stepGarbageCollector(self: *State, step: usize) bool {
        return callGc(self.handle(), c.LUA_GCSTEP, .{step}) != 0;
    }

    /// Set one of the collector's six parameters.
    pub fn setGarbageParameter(self: *State, parameter: GarbageParameter, value: c_int) void {
        _ = callGc(self.handle(), c.LUA_GCPARAM, .{ @backingInt(parameter), value });
    }

    /// Switch to generational collection; tune its multipliers with `setGarbageParameter`.
    pub fn setGenerational(self: *State) void {
        _ = callGc(self.handle(), c.LUA_GCGEN, .{});
    }

    /// Switch to incremental collection; tune its parameters with `setGarbageParameter`.
    pub fn setIncremental(self: *State) void {
        _ = callGc(self.handle(), c.LUA_GCINC, .{});
    }

    /// The parameters accepted by Lua's `LUA_GCPARAM` selector.
    pub const GarbageParameter = enum(c_int) {
        minor_multiplier = c.LUA_GCPMINORMUL,
        major_to_minor = c.LUA_GCPMAJORMINOR,
        minor_to_major = c.LUA_GCPMINORMAJOR,
        pause = c.LUA_GCPPAUSE,
        step_multiplier = c.LUA_GCPSTEPMUL,
        step_size = c.LUA_GCPSTEPSIZE,
    };

    /// Create a coroutine anchored on this stack and return a borrowed `ThreadRef`.
    /// The parent state owns it; allocation errors follow Lua's longjmp behavior.
    pub fn newThread(self: *State) ThreadRef {
        return .{ .raw = c.lua_newthread(self.handle()).? };
    }

    /// Push this state's thread and return its stack index.
    pub fn pushThread(self: *State) Index {
        return c.lua_pushthread(self.handle());
    }

    /// Return a thread's Lua status; unknown status codes return `Error.UnexpectedStatus`.
    pub fn statusOf(self: *const State) Error!Status {
        return Status.fromCode(c.lua_status(self.handle())) orelse error.UnexpectedStatus;
    }

    /// Whether this thread may yield now.
    pub fn isYieldable(self: *const State) bool {
        return c.lua_isyieldable(self.handle()) != 0;
    }
};

/// Route `lua_gc`'s variadic arguments through the selected C module.
fn callGc(handle: ?*c.lua_State, what: c_int, trailing: anytype) c_int {
    if (comptime runtime_loaded) {
        return c.lua_gc(handle, what, trailing);
    }
    return @call(.auto, c.lua_gc, .{ handle, what } ++ trailing);
}

/// Convert Lua's negative refusal result to null.
fn counted(value: c_int) ?c_int {
    return if (value < 0) null else value;
}

/// A non-owning coroutine view anchored on its parent's stack.
/// It is valid only while the owning state and stack anchor live.
pub const ThreadRef = struct {
    raw: *c.lua_State,

    /// Return the raw coroutine handle for unwrapped APIs.
    pub fn handle(self: ThreadRef) *c.lua_State {
        return self.raw;
    }

    /// Resume with `nargs` values; success returns the result count on this coroutine's stack.
    /// Failure leaves its error object there; `LUA_YIELD` maps to `Error.RuntimeError`.
    pub fn @"resume"(self: ThreadRef, nargs: Index) Error!usize {
        var nresults: Index = 0;
        const status = c.lua_resume(self.raw, null, nargs, &nresults);
        if (status == c.LUA_YIELD) return error.RuntimeError;
        try statusOk(status);
        return @intCast(nresults);
    }

    /// Whether this coroutine may yield now.
    pub fn isYieldable(self: ThreadRef) bool {
        return c.lua_isyieldable(self.raw) != 0;
    }
};

/// Lua status codes; `ok` and `yield` are normal thread states, not call errors.
/// `fromCode` returns null for unrecognized codes.
pub const Status = enum(c_int) {
    ok = c.LUA_OK,
    yield = c.LUA_YIELD,
    runtime = c.LUA_ERRRUN,
    syntax = c.LUA_ERRSYNTAX,
    memory = c.LUA_ERRMEM,
    error_in_error = c.LUA_ERRERR,
    file = c.LUA_ERRFILE,

    /// Return the status for `code`, or null when it is unknown.
    pub fn fromCode(code: c_int) ?Status {
        return switch (code) {
            c.LUA_OK => .ok,
            c.LUA_YIELD => .yield,
            c.LUA_ERRRUN => .runtime,
            c.LUA_ERRSYNTAX => .syntax,
            c.LUA_ERRMEM => .memory,
            c.LUA_ERRERR => .error_in_error,
            c.LUA_ERRFILE => .file,
            else => null,
        };
    }
};

/// Convert one Lua status to its `Error` tag; unknown codes return `UnexpectedStatus`.
/// Yield and file-error tags remain part of the shared status namespace.
fn statusOk(status: c_int) Error!void {
    switch (status) {
        c.LUA_OK => {},
        c.LUA_ERRSYNTAX => return error.SyntaxError,
        c.LUA_ERRMEM => return error.MemoryError,
        c.LUA_ERRRUN => return error.RuntimeError,
        c.LUA_ERRERR => return error.ErrorInErrorHandler,
        c.LUA_ERRFILE => return error.FileError,
        else => return error.UnexpectedStatus,
    }
}
