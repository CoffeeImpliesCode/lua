// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.

//! Zig facade over the Lua 5.5.1 C implementation.
//!
//! No part of the language is reimplemented here. Every value that comes back
//! out of this module was produced by the C under `src/`, reached through
//! `pub const c`, the module the translation step produces from
//! `zig/translate.h`. What the facade adds is the part a C header cannot
//! express: a state that owns itself and says what closing it means, stack
//! positions named instead of numbered by convention, byte-exact strings
//! returned as slices rather than as NUL-terminated pointers, and one honest
//! answer for each status code the C API can return.
//!
//! ## Import routes
//!
//! One Zig route is published: `dep.module("lua")` in the dependent's
//! `build.zig`, which is `@import("lua")` in source. The translated headers are
//! `c` on that same module and are not published as a module of their own, so
//! the declarations and the library that satisfies them arrive through one
//! route. A C consumer takes the installed headers and the installed library
//! instead; `README.zig.md` names that layout.
//!
//! ```zig
//! const lua = @import("lua");
//! const std = @import("std");
//!
//! pub fn main() !void {
//!     var state = try lua.State.init();
//!     defer state.deinit();
//!     state.openLibraries();
//!     try state.runChunk("return 6 * 7", "=smoke");
//!     const answer = state.toInteger(-1) orelse return error.NoAnswer;
//!     std.debug.print("{d}\n", .{answer});
//! }
//! ```
//!
//! ## Allocation
//!
//! This module allocates nothing and wraps nothing on the heap. `State` is one
//! optional pointer, `ThreadRef` is one pointer, and every string a getter
//! returns is a borrowed slice into memory the C library already owns.
//!
//! That ownership is upstream's, and it is worth stating plainly:
//! `luaL_newstate` calls `lua_newstate(luaL_alloc, NULL, ...)`
//! (`src/lauxlib.c:1197-1198`) and `luaL_alloc` calls libc's `realloc` and
//! `free` directly (`src/lauxlib.c:1062-1070`). Nothing here can bound,
//! intercept or account for those allocations, and a Zig test allocator cannot
//! be given a leak oracle for memory a third-party allocator owns. `deinit`
//! closes the state, which releases all of it; that is the whole answer this
//! module can give.
//!
//! ## Two configurations: linked and runtime-loaded
//!
//! This module is built in one of two shapes, and `runtime_loaded` says which
//! at comptime.
//!
//! *Linked* is the default. The C library is linked, `c` is the translation of
//! the three public headers, and every call below is a direct call with no
//! table and no check.
//!
//! *Runtime-loaded* is opt-in (`-Druntime`). The library is not linked; `c` is
//! a dispatch generated from the same translation step's output, and all 157
//! declarations the three headers make - 156 functions and the exported data
//! object `lua_ident` - are resolved through the platform loader when the
//! caller calls
//!
//! ```zig
//! try lua.load(.{ .path = "/usr/lib/liblua.so.55" });
//! ```
//!
//! before using anything else. A call into a module that has not loaded stops
//! the program with a message naming the function, in every optimization mode.
//! That is a programming error rather than a recoverable condition: the table
//! does not exist yet and there is no partial state to fall back on. The load
//! itself reports a missing file, a provider that does not export what the
//! headers declare, a request that cannot be honoured because a different
//! provider already won, or a reentrant call, as errors rather than as a
//! different library being loaded instead.
//!
//! The provider is reached, never guessed. `.path` names a file and `.system`
//! names a library for the platform loader; neither falls back to the other,
//! the module has no unload and no reset, and it keeps the handle and its own
//! copy of the request to the end of the process.
//!
//! `runtime/library.zig` states what a provider must be, including the Lua 5.5
//! external ABI family this SDK supports and why a LuaJIT 2.1 object is
//! refused rather than half used.
//!
//! ## Strings are bytes
//!
//! Lua strings are length-counted byte sequences, not C strings, and this
//! module keeps them that way. `pushBytes` takes a `[]const u8` and hands the
//! length to `lua_pushlstring`, so an embedded NUL survives; `toBytes` returns
//! a `[]const u8` whose length came from `lua_tolstring` rather than from a NUL
//! scan, and it is the exact byte count Lua holds. Nothing here trims at a NUL
//! or assumes UTF-8.
//!
//! One upstream behaviour is passed through rather than hidden: `lua_tolstring`
//! converts a number on the stack into a string in place (`src/lua.h:418`).
//! `toBytes` therefore returns a string for a numeric value and leaves that
//! value changed on the stack. `toNumber` and `toInteger` do not convert.
//!
//! ## Errors, and what is left on the stack
//!
//! `load`, `pcall` and `runChunk` return an error union rather than a status
//! code, and each error is one status code this file actually checked. When
//! they fail, upstream leaves exactly one value on the stack - the error object
//! - and this module leaves it there too: nothing is pushed, nothing is popped,
//! and the depth of everything below it is unchanged. That is what makes the
//! failure inspectable.
//!
//! `statusOf` is a fourth one and is a different shape: it reports the status a
//! thread was left in rather than the outcome of a call, so a stopped thread
//! is an answer and not a failure, and it can fail for exactly one reason - a
//! code `Status` has no tag for. It reads a field and pushes nothing, so the
//! rest of this section - what a failure leaves on the stack and how to read
//! it - does not apply to it.
//!
//! Three ways to read it, and the difference matters:
//!
//!   * `errorMessage` returns the bytes of the top value *without* removing
//!     it. The slice points into Lua's own string storage and stays valid until
//!     that stack slot is overwritten or collected. Nothing is copied.
//!   * `takeError` copies into a buffer you own and then removes the value.
//!     Use it when the text has to outlive the stack slot.
//!   * `discardError` removes the value and keeps nothing.
//!
//! The value on the stack is not always a string. `error({})` leaves a table,
//! and `error(42)` leaves a number that `lua_tolstring` would convert. Both
//! facts are reported rather than smoothed over: `errorMessage` returns null
//! for a value with no string form, and `typeOf(-1)` says what is actually
//! there.
//!
//! ## longjmp boundaries
//!
//! Several upstream entry points raise a Lua error by longjmp rather than by
//! returning: `lua_error`, `luaL_error`, `luaL_argerror`, `luaL_typeerror`
//! (`src/lauxlib.h:76,53,54`) and every `luaL_check*`/`luaL_argcheck` helper
//! built on them. A longjmp does not unwind a Zig frame; it skips it. A `defer`
//! that would have released memory does not run, and the error that was in
//! flight does not become a Zig error.
//!
//! This module therefore never calls them. It reaches them only through `c`,
//! and a caller who uses them takes the rule with them: call them only inside a
//! C function that Lua itself invoked, under a `lua_pcallk` that is still on
//! the stack, and hold nothing across them that a skipped `defer` would
//! otherwise have freed. `State.register` exists so such a callback can be
//! written as an ordinary `callconv(.c)` function without this module having an
//! opinion about what it does.
//!
//! ## Lifetime
//!
//! `State` owns one `lua_State` and closes exactly the one it created. `deinit`
//! takes `*State`, closes through the same `c` route that opened it - the same
//! provider in a runtime-loaded build - and then clears the field, so calling
//! it twice on the same variable is a no-op rather than a double free. Zig
//! cannot make a struct non-copyable, so the remaining rule is the usual one:
//! copy a `State` before `deinit` and you have two owners of one state, and
//! only one of them should close it.
//!
//! `ThreadRef` is the deliberate contrast. It is a non-owning view of a thread
//! `newThread` pushed, and it has no `deinit` at all: the thread belongs to the
//! state that created it, and closing it from a second place would run its
//! pending `__close` metamethods twice. See `ThreadRef`.
//!
//! ## Threading
//!
//! A `lua_State` is plain mutable state with no locking, so it belongs to one
//! thread at a time. Nothing else in this module is shared, because nothing
//! else is stateful except the loader's own table, which the loader core
//! synchronises.

const std = @import("std");

/// The translated `lua.h`, `lauxlib.h` and `lualib.h`, i.e. upstream's ABI
/// exactly as published.
///
/// This is the escape hatch for a declaration the facade does not name
/// (`lua_dump`, `lua_getinfo`, the `luaL_Buffer` builders, `luaL_loadfilex`,
/// `lua_pushvfstring` and its `va_list`, every `luaL_check*` helper), and for
/// the macro-defined operations below. It is the same module the facade calls,
/// on the same library, so importing the facade is all a dependent needs to
/// reach it; it is not published under a name of its own.
///
/// The declarations are for whichever headers this build selected: bundled mode
/// translates `src/lua.h`, `src/lauxlib.h` and `src/lualib.h`, system mode the
/// installed ones. A caller that reaches past the facade gets upstream
/// behaviour and inherits every obligation upstream declares.
///
/// ## The macros, and what they become
///
/// Upstream's convenience operations are C macros, and the translation step
/// carries each one into `c` as `pub inline fn NAME(params: anytype) T` whose
/// body is the macro's own expansion: `c.lua_pop(L, n)` is
/// `lua_settop(L, -(n)-1)` (`src/lua.h:396`), `c.lua_newtable(L)` is
/// `lua_createtable(L, 0, 0)` (`src/lua.h:398`), and a comma expression
/// lowers too - the leading calls discarded, the last one returned - so
/// `c.luaL_newlib(L, l)` is `src/lauxlib.h:135-136`, its version check and its
/// table-sized-from-the-array thrown away and `luaL_setfuncs` returned. A macro
/// whose body names another macro expands that one too: `lua_remove` is
/// `src/lua.h:423` and arrives calling `lua_pop` (`src/lua.h:396`) rather than
/// repeating it.
///
/// Observed in a `zig translate-c` of this package's own `zig/translate.h`;
/// the excerpt of the translator's output that decides these shapes is
/// `local://foundation-contract-lua-real-translate-c-macro-and-variadic-shapes.log`.
///
/// Which names take that shape is the translation's business rather than a
/// promise this module makes: one it cannot lower at all is a `pub const` whose
/// value is `@compileError`, which is a name that cannot be called. Five of
/// this library's own are of that kind - `luaL_addchar`
/// (`src/lauxlib.h:201-203`, whose `B->n++` is not lowered), `luaL_addsize`
/// (`:205`), `luaL_buffsub` (`:207`), `lua_str2number`
/// (`src/luaconf.h:457`) and `lua_getlocaledecpoint` (`:644`) - and the
/// `luaL_Buffer` builders are ordinary declarations beside them
/// (`src/lauxlib.h:209-216`), so that API is reachable either way.
///
/// None of this is a second native symbol, and none of it is routed. Only
/// `extern` declarations are (`runtime/generate.zig:519-527`), so a wrapper is
/// copied into a runtime-loaded dispatch and `:462-465` rewrites it to call
/// the routed function it expands to. A provider exports nothing for any of
/// them.
///
/// The expansions, and the method that spells the same call:
///
///   * `lua_pop(L,n)` is `lua_settop(L, -(n)-1)` (`src/lua.h:396`), which is
///     what `State.discardError` calls.
///   * `lua_newtable(L)` is `lua_createtable(L, 0, 0)` (`src/lua.h:398`), which
///     is what `State.newTable` with two zeroes does.
///   * `lua_tostring(L,i)` is `lua_tolstring(L, i, NULL)`
///     (`src/lua.h:418`); the length is what `State.toBytes` returns.
///   * `lua_call(L,n,r)` is `lua_callk(L, n, r, 0, NULL)` (`src/lua.h:295`) and
///     `lua_pcall(L,n,r,f)` is `lua_pcallk(L, n, r, f, 0, NULL)`
///     (`src/lua.h:299`); both are what `State.call` and `State.pcall` call.
///   * `lua_pushcfunction(L,f)` is `lua_pushcclosure(L, f, 0)`
///     (`src/lua.h:402`), which is what `State.register` does.
///   * `lua_pushglobaltable(L)` is a raw `lua_rawgeti` on the registry
///     (`src/lua.h:415-416`), which this module spells out for you.
///   * `luaL_openlibs(L)` is `luaL_openselectedlibs(L, ~0, 0)`
///     (`src/lualib.h:62`), which is what `State.openLibraries` calls.
///   * `luaL_dostring`/`luaL_dofile` (`src/lauxlib.h:149-153`) compose a load
///     and a protected call; `State.runChunk` composes the same two steps and
///     leaves the error object in place when the second one fails.
///   * `luaL_newlib` (`src/lauxlib.h:135-136`) is three calls in a comma
///     expression - a version check, a table sized from the array, then its
///     entries - which `State.newTable` followed by `State.setFunctions` is.
///   * `lua_getextraspace(L)` is `((void *)((char *)(L) - LUA_EXTRASPACE))`
///     (`src/lua.h:391`) and reaches that as a callable wrapper, which is what
///     a caller who wants it calls; nothing in this module does.
///   * `lua_resetthread(L)` is `lua_closethread(L, NULL)`
///     (`src/lua.h:440`), and `lua_close(L)` is `lua_closethread(L, L)`.
///
/// In a runtime-loaded build this module is a generated dispatch instead of the
/// translation step's own output. It publishes the same namespace: every type
/// and constant is re-exported from the translation rather than restated, so
/// `State` is the same nominal type either way and nothing here needs a cast.
///
/// The three real C variadics - `lua_pushfstring`, `luaL_error` and `lua_gc` -
/// are the one place the two configurations do not have the same shape. The
/// dispatch keeps their arity and takes the trailing arguments as one final
/// tuple, while the translation's own `extern fn` is a C variadic and takes
/// them as promoted arguments. Every call to one of them is a comptime branch
/// on `runtime_loaded`, so a build resolves only the route it has and a reader
/// of one route is reading the one that will run. `runtime_loaded` says which
/// configuration this build is, at comptime.
pub const c = @import("c");

/// The loader core, which is where a linked build's two public types come
/// from.
///
/// It is imported only by the linked configuration. In a runtime-loading build
/// the dispatch carries its own copy of the same declarations, and this module
/// is never referenced, so it is never resolved and never compiled. Either way
/// there is exactly one `LoadSource` and one `LoadError` in a build, which is
/// what keeps them one type for a consumer that names them.
const rt = @import("rt");

/// Whether this module was configured to resolve its native symbols at run
/// time.
///
/// False for the ordinary build, where the C library is linked and `c` is the
/// translation of the three public headers. True when the build generated a
/// dispatch that resolves the same symbols through the platform loader, in
/// which case `load` is the call that makes the library usable.
///
/// It is a comptime constant, so a consumer can write two different code paths
/// and have only the one it chose analyzed.
pub const runtime_loaded: bool = if (@hasDecl(c, "rt_runtime_loaded")) c.rt_runtime_loaded else false;

/// Which native library `load` should open.
///
/// `.path` is an explicit file path and `.system` is an explicit name for the
/// platform loader. There is no path-to-system fallback and no implicit
/// fallback of any kind; a request that cannot be honoured is an error, not a
/// different library.
pub const LoadSource = if (runtime_loaded) c.LoadSource else rt.LoadSource;

/// Every way `load` can decline.
///
/// Declared here, in the module a consumer imports, rather than only inside the
/// loader: the caller names the failure it is handling.
pub const LoadError = if (runtime_loaded) c.LoadError else rt.LoadError;

/// Load the native library this module dispatches to.
///
/// In a runtime-loading build this is the whole contract: call it once, then
/// use this module as if it were linked. Calling it again with the same request
/// succeeds and changes nothing; calling it with a different request after a
/// success is `ProviderMismatch`, and the library already in use stays in use.
/// A failed attempt publishes nothing and can be retried explicitly, by
/// calling this again: there is no automatic retry and no implicit second
/// source.
///
/// It keeps the process handle and its own copy of the request to the end of
/// the process. There is no unload and no reset, because the table is
/// process-global state that other code may already have called through.
///
/// Safe to call from any thread. A thread that arrives while an attempt for the
/// same request is in flight waits for that attempt and gets its result,
/// whatever it was. A call from the thread that is running the attempt is
/// `ReentrantLoad` rather than a deadlock.
///
/// In a linked build there is no provider, no table and nothing to resolve, so
/// this stops the program with a message saying so instead of quietly
/// succeeding. `runtime_loaded` is false there, so a consumer that supports
/// both configurations can tell the two apart at comptime instead of meeting
/// this at run time.
pub fn load(source: LoadSource) LoadError!void {
    // `c.load` exists only in a runtime-loading build. The condition is known
    // at comptime, so the branch this build does not take is never analyzed
    // and never names it; the same gate `version_ident` below uses, for the
    // same reason.
    if (runtime_loaded) return c.load(source);
    std.debug.panic(
        "lua: load was called on a linked build; this module is not " ++
            "runtime-loaded, so there is no library to load. Build with " ++
            "runtime loading configured, or do not call load.",
        .{},
    );
}

/// The request that succeeded, or null when nothing has loaded yet.
///
/// The answer is the loader's own retained copy and stays valid for the life of
/// the process. Null in a linked build, which has no request.
pub fn loadedSource() ?LoadSource {
    if (runtime_loaded) return c.loadedSource();
    return null;
}

/// A stack index, exactly as the C API numbers them.
///
/// 1 is the bottom of the stack, -1 is the top, and a pseudo-index is a
/// negative number far below it.
pub const Index = c_int;

/// The numeric family of the API this translation describes: major times one
/// hundred plus minor, so 505 for Lua 5.5 (`src/lua.h:20-24`).
///
/// This is the value `lua_version` answers with and the value
/// `runtime/library.zig` requires of a runtime-loaded provider.
pub const version_num: i32 = c.LUA_VERSION_NUM;

/// The release number: `version_num * 100 + release`, so 50501 for Lua 5.5.1
/// (`src/lua.h:25`).
pub const version_release_num: i32 = c.LUA_VERSION_RELEASE_NUM;

/// The four bytes every precompiled Lua chunk starts with, `<esc>Lua`
/// (`src/lua.h:32`). `lua_load` rejects a binary chunk that does not begin
/// with them.
pub const signature: [:0]const u8 = c.LUA_SIGNATURE;

/// The pseudo-index the registry lives at (`src/lua.h:43`).
pub const registry_index: Index = c.LUA_REGISTRYINDEX;

/// The pseudo-index of upvalue `n` (`src/lua.h:44`).
pub fn upvalue_index(n: Index) Index {
    return registry_index - n;
}

/// How many stack slots a C function can count on without asking
/// (`src/lua.h:79`). `checkStack` is how you ask for more.
pub const min_stack: usize = c.LUA_MINSTACK;

/// Pass this as `nresults` to keep every result a call produced instead of
/// picking a number (`src/lua.h:35`).
pub const multret: Index = c.LUA_MULTRET;

/// The copyright and author banner the library reports in `lua_ident`, read
/// from the provider's own exported data rather than from a constant compiled
/// into this program.
///
/// `lua_ident` is a `const char[]`, so the value is a NUL-terminated string in
/// the provider's storage. In a runtime-loaded build it arrives through the
/// dispatch table as the provider's address, never as a copy, which is what
/// makes this a fact about the provider.
pub fn version_ident() [:0]const u8 {
    if (comptime runtime_loaded) return std.mem.span(c.lua_identAddr());
    return std.mem.span(c.lua_ident);
}

/// What one of Lua's ten standard libraries is called and what opens it.
///
/// The name, the opener and the mask bit are upstream's own
/// (`src/lualib.h:20-56` and `src/lauxlib.h:20`), read through `c` rather than
/// restated, so a name that moved upstream cannot silently disagree here. The
/// order of the enum is the order of the bits, which is also the order
/// `src/linit.c:28-40` requires the openers to be listed in.
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

    /// The name this library is bound to in `_G` and in `package.loaded`.
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

    /// The `luaopen_*` entry point, typed as the function pointer the C API
    /// registers.
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

    /// This library's bit in the mask `luaL_openselectedlibs` and
    /// `openSelectedLibraries` take.
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

/// The nine basic types a Lua value can have, plus "nothing there"
/// (`src/lua.h:62-75`).
///
/// `none` is not a value: it is what `lua_type` answers for an index that does
/// not exist, which is how a caller tells "the stack slot holds nil" from "the
/// stack slot does not exist".
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

/// How a comparison is to be made, for `State.compare`
/// (`src/lua.h:232-234`).
///
/// These ask Lua, metamethods included; `State.rawEqual` is the identity test
/// that ignores them.
pub const CompareOp = enum(c_int) {
    eq = c.LUA_OPEQ,
    lt = c.LUA_OPLT,
    le = c.LUA_OPLE,
};

/// Which arithmetic `State.arith` performs (`src/lua.h:215-228`).
///
/// The operand order is the one upstream documents: for the two-operand
/// operations the second value on the stack is the left one.
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

/// Every way a protected step can fail.
///
/// One tag per status code `src/lua.h:48-53` and `src/lauxlib.h:27` define: the
/// vocabulary is the C status namespace this module funnels through, so that a
/// status code has one name here whether a typed call or the raw `c` route
/// produced it. That makes it an upper bound over any single call rather than
/// a list of what one call reached, and a caller reading a switch has to know
/// which is which. It is, per method:
///
///   * `load` and `loadChunk` reach `SyntaxError` and `MemoryError`, through
///     `luaL_loadbufferx`.
///   * `pcall` reaches `RuntimeError`, `ErrorInErrorHandler` and `MemoryError`,
///     but never `SyntaxError`: it calls a value already on the stack, and the
///     compile that would raise that code happened in `load`. `runChunk` is
///     `load` then `pcall`, so it reaches all four.
///   * `resume` reaches the same three. `LUA_ERRMEM` is the one code all three
///     share for a reason no caller controls: it is thrown from anywhere inside
///     the protected call by an allocation that cannot be satisfied, and
///     `luaD_throw` is what carries it back out as the status the caller reads
///     (`src/ldo.c:125-128`, `:1090-1099`) - and `resume` reports `LUA_YIELD`
///     as `RuntimeError`, which its own doc comment says why.
///   * `FileError` is reachable from **none** of them. `LUA_ERRFILE` has one
///     producer in the whole tree - `src/lauxlib.c:774-783`, in `errfile`, which
///     only `luaL_loadfilex` can reach - and this module does not wrap that
///     function. It is named here because it is part of the shared vocabulary,
///     and a caller that reaches past the facade through `pub const c` and calls
///     `c.luaL_loadfilex` gets that status back as a raw `c_int` and can name it
///     with `Status.file` or catch it here.
///
/// `UnexpectedStatus` covers a code outside that namespace, which upstream's
/// documentation says cannot happen for a call or a load but which is reported
/// rather than treated as success. `statusOf` is the other function that can
/// return it: it reads the status a thread was left in rather than the result
/// of a call.
pub const Error = error{
    /// `LUA_ERRSYNTAX`: the chunk did not compile.
    SyntaxError,
    /// `LUA_ERRMEM`: memory for the operation could not be obtained.
    MemoryError,
    /// `LUA_ERRRUN`: the chunk, or something it called, raised an error.
    RuntimeError,
    /// `LUA_ERRERR`: the error handler itself raised an error.
    ErrorInErrorHandler,
    /// `LUA_ERRFILE`: a file could not be opened or read. No typed call in this
    /// module reaches it; see the note on the set for the one route that does.
    FileError,
    /// A status code with no tag above. See the note on the set.
    UnexpectedStatus,
};

/// A C function Lua can call, which is `lua_CFunction` itself.
///
/// The type is upstream's, not a Zig invention: `int (*)(lua_State *)`
/// (`src/lua.h:106`). Registering one is `State.register`, and what such a
/// function does when it wants to fail is described under "longjmp boundaries"
/// above: it longjmps, and it may only do so inside a call Lua made.
pub const CFunction = c.lua_CFunction;

/// The state this SDK was built to talk to, and the object that owns it.
///
/// A `State` owns exactly one `lua_State`. `init` creates one through
/// `luaL_newstate`, `deinit` closes that one through the same route, and
/// nothing else closes it. Copying the struct copies the ownership; see
/// "Lifetime" above.
pub const State = struct {
    /// The owned state, or null once `deinit` has run.
    raw: ?*c.lua_State = null,

    /// The one failure `init` and `initWithLibraries` can report, which is
    /// upstream's own out-of-memory condition and not a refusal to try. What
    /// creating a state can mean is described under `init`.
    pub const InitError = error{OutOfMemory};

    /// A state with no standard libraries loaded.
    ///
    /// `luaL_newstate` returns null only when its allocator cannot satisfy the
    /// state itself, which upstream reports as an out-of-memory condition; that
    /// is the single null this function maps, and nothing else.
    ///
    /// Use `initWithLibraries` when the state is going to run scripts: without
    /// `openLibraries` the globals table has none of `string`, `table`, `math`,
    /// `os`, `io`, `coroutine`, `debug`, `utf8` or `package` in it, and a chunk
    /// that says `string.format` raises "attempt to index a nil value".
    pub fn init() InitError!State {
        const raw = c.luaL_newstate() orelse return error.OutOfMemory;
        return .{ .raw = raw };
    }

    /// A state with all ten standard libraries loaded, which is what
    /// `luaL_openlibs` gives.
    pub fn initWithLibraries() InitError!State {
        var self = try init();
        self.openLibraries();
        return self;
    }

    /// Close the state and everything it owns.
    ///
    /// The close goes through the same `c` route that opened the state, so a
    /// state created by one provider is always closed by that provider. The
    /// field is cleared afterwards, which makes a second `deinit` on the same
    /// variable a no-op instead of a second close.
    pub fn deinit(self: *State) void {
        const raw = self.raw orelse return;
        self.raw = null;
        c.lua_close(raw);
    }

    /// Whether this state is still open.
    pub fn isOpen(self: *const State) bool {
        return self.raw != null;
    }

    /// The state itself, for anything the facade does not wrap.
    ///
    /// Stopping the program on a closed state is deliberate: a call into a
    /// closed `lua_State` is not a condition to recover from, and the field is
    /// null precisely so that this is caught at the call rather than inside
    /// the C library.
    pub fn handle(self: *const State) *c.lua_State {
        return self.raw orelse @panic(
            "lua: this State was closed; deinit() clears the handle and there is " ++
                "no state left to call. Check isOpen() if the lifetime is not " ++
                "obvious.",
        );
    }

    /// Load every standard library into the globals table.
    ///
    /// This is `luaL_openlibs`, which is `luaL_openselectedlibs(L, ~0, 0)`
    /// (`src/lualib.h:62`). Calling it twice is not an error and not a
    /// replacement: upstream re-requires each library, which returns the table
    /// that is already there.
    pub fn openLibraries(self: *State) void {
        c.luaL_openselectedlibs(self.handle(), -1, 0);
    }

    /// Load only the libraries whose bits are set in `mask`.
    ///
    /// The bits are `Library.mask`, and a caller that wants "everything" wants
    /// `openLibraries`. `load` and `preload` are the two halves of upstream's
    /// argument pair (`src/linit.c:46-62`): a library that is loaded becomes a
    /// global, and one that is only preloaded becomes an entry in
    /// `package.preload` and is opened on the first `require`.
    pub fn openSelectedLibraries(self: *State, mask: c_int, preload: c_int) void {
        c.luaL_openselectedlibs(self.handle(), mask, preload);
    }

    /// Load one library and leave nothing behind on the stack.
    ///
    /// `luaL_requiref` pushes the module table (`src/lauxlib.c:1016-1018`) and
    /// this removes it, which is what `luaL_openselectedlibs` does for each
    /// library it loads (`src/linit.c:52-53`). Opening a library that is already
    /// open returns the existing table rather than rebuilding it.
    pub fn openLibrary(self: *State, lib: Library) void {
        const state = self.handle();
        c.luaL_requiref(state, lib.name(), lib.opener(), 1);
        self.discardTop();
    }

    /// Put the globals table on the stack, which is what
    /// `lua_pushglobaltable` does (`src/lua.h:415-416`).
    pub fn pushGlobals(self: *State) void {
        c.lua_rawgeti(self.handle(), registry_index, c.LUA_RIDX_GLOBALS);
    }

    // -----------------------------------------------------------------------
    // Stack shape
    // -----------------------------------------------------------------------

    /// The index of the top element, so zero for an empty stack.
    pub fn getTop(self: *const State) Index {
        return c.lua_gettop(self.handle());
    }

    /// Move the top to `index`.
    ///
    /// A negative index counts from the current top, which is what makes
    /// `setTop(-1)` the way to remove one value and `discardTop` what it is.
    pub fn setTop(self: *State, index: Index) void {
        c.lua_settop(self.handle(), index);
    }

    /// Remove the value on top, and only that one.
    ///
    /// `lua_pop(L, 1)` is a macro for exactly this call
    /// (`src/lua.h:396`); there is no `lua_pop` symbol to route.
    pub fn discardTop(self: *State) void {
        c.lua_settop(self.handle(), -2);
    }

    /// Make sure there is room for `n` more values, growing the stack if there
    /// is not.
    ///
    /// This can move values that are already on the stack, so anything a
    /// caller is holding by raw index should be re-based with `absIndex`
    /// afterwards. `absIndex` is the only correct way to keep an index across a
    /// call like this one, `luaL_checkstack` and a push.
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

    /// Rotate the `n` values from `index` up by `n` positions.
    ///
    /// `insert` is `rotate(idx, 1)` and `remove` is `rotate(idx, -1)` followed
    /// by removing the top (`src/lua.h:421-423`), which is what
    /// `insertTop` does for the first and what the caller does for the second.
    pub fn rotate(self: *State, index: Index, n: Index) void {
        c.lua_rotate(self.handle(), index, n);
    }

    /// Insert the value on top of the stack at `index`.
    pub fn insertTop(self: *State, index: Index) void {
        self.rotate(index, 1);
    }

    /// Copy the value at `from` over the one at `to`, keeping both slots.
    ///
    /// `replace` is this followed by removing the top (`src/lua.h:425`).
    pub fn copy(self: *State, from: Index, to: Index) void {
        c.lua_copy(self.handle(), from, to);
    }

    /// Move `n` values from the top of this state to the top of `to`.
    ///
    /// This is how values cross between a state and one of its coroutines.
    pub fn move(self: *State, to: *const State, n: Index) void {
        c.lua_xmove(self.handle(), to.handle(), n);
    }

    // -----------------------------------------------------------------------
    // Pushing
    // -----------------------------------------------------------------------

    /// Push a nil, which is `lua_pushnil` (`src/lua.h:243`).
    ///
    /// Nil is how Lua says "nothing here", and it is a value rather than the
    /// absence of one: `typeOf` reads a pushed nil back as `Type.nil`, which is
    /// a different answer from the `Type.none` an index past the top gives.
    pub fn pushNil(self: *State) void {
        c.lua_pushnil(self.handle());
    }

    /// Push a boolean. Any integer is true in Lua, so this takes a `bool` and
    /// the caller does not have to know that.
    pub fn pushBoolean(self: *State, value: bool) void {
        c.lua_pushboolean(self.handle(), @intFromBool(value));
    }

    /// Push an integer. This is `lua_Integer`, 64 bits wide in the
    /// configuration this package builds (`src/luaconf.h:136`).
    pub fn pushInteger(self: *State, value: i64) void {
        c.lua_pushinteger(self.handle(), value);
    }

    /// Push a float. This is `lua_Number`, `double` in that same
    /// configuration (`src/luaconf.h:137`).
    pub fn pushNumber(self: *State, value: f64) void {
        c.lua_pushnumber(self.handle(), value);
    }

    /// Push bytes, without a NUL anywhere in the contract.
    ///
    /// `lua_pushlstring` is given the length, so an embedded NUL is part of the
    /// string rather than its end, and nothing is copied on this side of the
    /// call. The returned slice is the string Lua now holds, with the length
    /// that was just pushed rather than a NUL scan, so it is the whole string
    /// even when one of its bytes is a NUL; it is not the caller's buffer,
    /// which may be reused as soon as this returns.
    pub fn pushBytes(self: *State, bytes: []const u8) []const u8 {
        const text = c.lua_pushlstring(self.handle(), bytes.ptr, bytes.len);
        return text[0..bytes.len];
    }

    /// Push an opaque address with no Lua-level identity.
    ///
    /// A light userdata is compared by address and is never collected, which is
    /// the whole difference from `newUserdata`.
    pub fn pushLightUserdata(self: *State, pointer: ?*anyopaque) void {
        c.lua_pushlightuserdata(self.handle(), pointer);
    }

    /// Push a fresh userdata block of `size` bytes, with `userValues`
    /// associated instance values.
    ///
    /// The block is zeroed by Lua and owned by the collector; the pointer is
    /// only valid until the collector reclaims it, so keeping one across a
    /// collection is a use-after-free the type cannot catch. This is why the
    /// typed surface does not wrap it in an owning type.
    pub fn newUserdata(self: *State, size: usize, userValues: Index) ?*anyopaque {
        return c.lua_newuserdatauv(self.handle(), size, userValues);
    }

    // -----------------------------------------------------------------------
    // Reading
    // -----------------------------------------------------------------------

    /// What kind of value is at `index`, `Type.none` for an index that does not
    /// exist.
    pub fn typeOf(self: *const State, index: Index) Type {
        return @fromBackingInt(@intCast(c.lua_type(self.handle(), index)));
    }

    /// Upstream's own name for a type, such as `"string"` or `"nil"`
    /// (`src/lua.h:198`). Null for a type code no version of Lua defines.
    pub fn typeNameOf(self: *State, type_code: Type) ?[:0]const u8 {
        const text = c.lua_typename(self.handle(), @backingInt(type_code));
        if (text == null) return null;
        return std.mem.span(text);
    }

    /// Upstream's own name for what is at `index`.
    pub fn typeNameAt(self: *State, index: Index) ?[:0]const u8 {
        return self.typeNameOf(self.typeOf(index));
    }

    /// The integer at `index`, or null when it holds something with no exact
    /// integer value.
    ///
    /// This is the `lua_tointegerx` form, so it answers for a float that has
    /// an exact integer value and refuses one that does not, and it never
    /// changes the stack.
    pub fn toInteger(self: *const State, index: Index) ?i64 {
        var is_number: c_int = 0;
        const value = c.lua_tointegerx(self.handle(), index, &is_number);
        if (is_number == 0) return null;
        return value;
    }

    /// The float at `index`, or null when it holds something that is not a
    /// number.
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

    /// The bytes at `index`, with the length Lua holds rather than a NUL scan.
    ///
    /// A Lua string is a byte sequence with a length, and a NUL in it is an
    /// ordinary byte, so this is the only way to read a string without losing
    /// data. The returned slice points into memory Lua owns; it stays valid
    /// until that stack slot is overwritten or collected, and nothing is copied
    /// to make it.
    ///
    /// Upstream's own behaviour is passed through rather than hidden: a value
    /// that is a number is *converted to a string on the stack* by
    /// `lua_tolstring` (`src/lua.h:418`), so after this call that slot holds a
    /// string where it held a number. Anything with no string form - a table, a
    /// function, `nil` - gives null.
    pub fn toBytes(self: *State, index: Index) ?[]const u8 {
        var length: usize = 0;
        const text = c.lua_tolstring(self.handle(), index, &length);
        if (text == null) return null;
        return text[0..length];
    }

    /// The length of a string, table or userdata without converting anything
    /// (`src/lua.h:204`). This is the honest length of `"a\0b"`, which is 3.
    pub fn rawLength(self: *const State, index: Index) usize {
        const length = c.lua_rawlen(self.handle(), index);
        return std.math.cast(usize, length) orelse std.math.maxInt(usize);
    }

    /// An address that identifies the value at `index`.
    ///
    /// For a collectable object this is the object's own address, so two
    /// pushes of the same table give the same pointer and a table built twice
    /// does not. For a number it is an address of an internal fake object that
    /// is stable for that value, which upstream says must not be dereferenced.
    pub fn toPointer(self: *const State, index: Index) ?*const anyopaque {
        return c.lua_topointer(self.handle(), index);
    }

    /// The C function at `index`, when that is what it is.
    pub fn toCFunction(self: *const State, index: Index) ?CFunction {
        return c.lua_tocfunction(self.handle(), index);
    }

    /// The thread at `index`, when that is what it is.
    pub fn toThread(self: *const State, index: Index) ?ThreadRef {
        const raw = c.lua_tothread(self.handle(), index) orelse return null;
        return .{ .raw = raw };
    }

    // -----------------------------------------------------------------------
    // Tables and globals
    // -----------------------------------------------------------------------

    /// Push a new empty table, with sizes the array and hash parts are
    /// pre-sized for. Both hints may be zero.
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

    /// Push `table[key]`, going through metamethods.
    pub fn getField(self: *State, index: Index, key: [:0]const u8) void {
        _ = c.lua_getfield(self.handle(), index, key);
    }

    /// Pop the value on top into `table[key]`, going through metamethods.
    pub fn setField(self: *State, index: Index, key: [:0]const u8) void {
        c.lua_setfield(self.handle(), index, key);
    }

    /// Push `table[n]`, going through metamethods.
    pub fn getIndex(self: *State, index: Index, key: i64) void {
        _ = c.lua_geti(self.handle(), index, key);
    }

    /// Pop the value on top into `table[n]`, going through metamethods.
    pub fn setIndex(self: *State, index: Index, key: i64) void {
        c.lua_seti(self.handle(), index, key);
    }

    /// Push `table[n]` without going through metamethods.
    pub fn rawGetIndex(self: *State, index: Index, key: i64) void {
        _ = c.lua_rawgeti(self.handle(), index, key);
    }

    /// Pop the value on top into `table[n]` without going through metamethods.
    pub fn rawSetIndex(self: *State, index: Index, key: i64) void {
        c.lua_rawseti(self.handle(), index, key);
    }

    /// Whether two values are the same object, or primitively equal, ignoring
    /// every metamethod.
    pub fn rawEqual(self: *const State, a: Index, b: Index) bool {
        return c.lua_rawequal(self.handle(), a, b) != 0;
    }

    /// Compare two values the way the `==`, `<` and `<=` operators do,
    /// metamethods included.
    pub fn compare(self: *const State, a: Index, b: Index, op: CompareOp) bool {
        return c.lua_compare(self.handle(), a, b, @backingInt(op)) != 0;
    }

    /// Perform one arithmetic or bitwise operation on the values on top.
    pub fn arith(self: *State, op: ArithOp) void {
        c.lua_arith(self.handle(), @backingInt(op));
    }

    /// Concatenate the `n` values on top into one, left to right.
    pub fn concat(self: *State, n: Index) void {
        c.lua_concat(self.handle(), n);
    }

    /// Replace the value at `index` with its length, going through a `__len`
    /// metamethod if there is one.
    pub fn lengthOf(self: *State, index: Index) void {
        c.lua_len(self.handle(), index);
    }

    // -----------------------------------------------------------------------
    // Loading and calling
    // -----------------------------------------------------------------------

    /// Compile `source` and push the resulting function.
    ///
    /// `chunk_name` is what appears in error messages and in tracebacks, and
    /// `mode` restricts what text is accepted: `"b"` allows binary chunks,
    /// `"t"` text only, `"bt"` both. Null means upstream's default, text and
    /// binary.
    ///
    /// On success exactly one value is pushed and the stack is otherwise
    /// untouched. On failure the error object is left on top, `error.SyntaxError`
    /// or `error.MemoryError` is returned, and nothing below it moved.
    pub fn load(
        self: *State,
        source: []const u8,
        chunk_name: ?[:0]const u8,
        mode: ?[:0]const u8,
    ) Error!void {
        // Upstream takes both of these as plain `const char *`
        // (`src/lauxlib.h:100-101`) and both have a null as upstream's own
        // answer rather than as a failure: a null chunk name is `"?"`
        // (`src/lapi.c:1126`) and a null mode is `"bt"`, text and binary
        // (`src/ldo.c:1132`). So an absent optional is handed over as the null
        // pointer it stands for rather than as a slice with nothing behind it.
        const status = c.luaL_loadbufferx(
            self.handle(),
            source.ptr,
            source.len,
            if (chunk_name) |name| name.ptr else null,
            if (mode) |accepted| accepted.ptr else null,
        );
        try statusOk(status);
    }

    /// Compile `source` with a name upstream recognises as a literal chunk.
    pub fn loadChunk(self: *State, source: []const u8, chunk_name: [:0]const u8) Error!void {
        return self.load(source, chunk_name, null);
    }

    /// Call the function on top, unprotected.
    ///
    /// This is `lua_call`, which is `lua_callk(L, n, r, 0, NULL)`
    /// (`src/lua.h:295`). There is no error path: a Lua error raised below this
    /// call unwinds past this frame, and so past any `defer` a caller put
    /// around it. Use `pcall` unless the function is known not to raise.
    pub fn call(self: *State, nargs: Index, nresults: Index) void {
        c.lua_callk(self.handle(), nargs, nresults, 0, null);
    }

    /// Call the function on top, protected.
    ///
    /// `nargs` values above the function are consumed and the results replace
    /// it; `multret` keeps all of them. A non-zero `error_func` index installs a
    /// message handler, and zero means none.
    ///
    /// On failure the error object is left on top and nothing below it moved, so
    /// `errorMessage` can read it and `discardError` can remove exactly it.
    pub fn pcall(self: *State, nargs: Index, nresults: Index, error_func: Index) Error!void {
        const status = c.lua_pcallk(self.handle(), nargs, nresults, error_func, 0, null);
        try statusOk(status);
    }

    /// Load `source` and run it, with no arguments and no results.
    ///
    /// This is `luaL_dostring` (`src/lauxlib.h:152-153`), except that a failure
    /// is returned rather than turned into a return value, and the error object
    /// is left on the stack in both failure cases: the compiler's message for a
    /// syntax error, and the raised value for a runtime error.
    pub fn runChunk(self: *State, source: []const u8, chunk_name: [:0]const u8) Error!void {
        try self.load(source, chunk_name, null);
        try self.pcall(0, 0, 0);
    }

    /// The error object on top of the stack, as bytes, without removing it.
    ///
    /// The slice points into Lua's own storage and stays valid until that slot
    /// is overwritten or collected. Nothing is copied. Null when the value on
    /// top has no string form - a table, for instance, which is what
    /// `error({})` leaves behind; `typeOf(-1)` says what it actually is.
    pub fn errorMessage(self: *State) ?[]const u8 {
        return self.toBytes(-1);
    }

    /// Copy the error object on top into `buffer` and remove it.
    ///
    /// Use this when the text has to outlive the stack slot; `errorMessage` is
    /// the one to reach for when it does not, because it copies nothing.
    ///
    /// On `error.NoErrorMessage` or `error.ErrorBufferTooSmall` the value is
    /// deliberately left where it is, so the caller can still read it or
    /// discard it themselves. That is the only honest behaviour for a function
    /// that has not managed to take the value.
    pub fn takeError(self: *State, buffer: []u8) TakeError![]const u8 {
        const message = self.toBytes(-1) orelse return error.NoErrorMessage;
        if (message.len > buffer.len) return error.ErrorBufferTooSmall;
        @memcpy(buffer[0..message.len], message);
        self.discardTop();
        return buffer[0..message.len];
    }

    /// Why `takeError` did not take the value off the stack.
    ///
    /// Neither tag means the error object was lost: both leave it exactly
    /// where it was, so the caller can still read it with `errorMessage` or
    /// remove it with `discardError`.
    pub const TakeError = error{
        /// The value on top has no string form.
        NoErrorMessage,
        /// `buffer` is too small for the message; the value is still on the
        /// stack.
        ErrorBufferTooSmall,
    };

    /// Remove the error object on top, keeping nothing.
    pub fn discardError(self: *State) void {
        self.discardTop();
    }

    // -----------------------------------------------------------------------
    // Callbacks
    // -----------------------------------------------------------------------

    /// Push a C function with `upvalues` values already on the stack taken as
    /// its upvalues.
    pub fn pushCClosure(self: *State, function: CFunction, upvalues: Index) void {
        c.lua_pushcclosure(self.handle(), function, upvalues);
    }

    /// Register `function` as the global `name`.
    ///
    /// This is `lua_register`, which is `lua_pushcfunction` followed by
    /// `lua_setglobal` (`src/lua.h:400-402`). The function itself is an
    /// ordinary `callconv(.c)` function of type `CFunction`; what it does when
    /// it wants to fail is the longjmp rule described at the top of this file,
    /// and this function takes no position on it beyond not calling anything
    /// itself.
    pub fn register(self: *State, name: [:0]const u8, function: CFunction) void {
        self.pushCClosure(function, 0);
        self.setGlobal(name);
    }

    /// Register a whole table of functions at once, which is `luaL_setfuncs`.
    ///
    /// `entries` must be terminated by a zeroed record: `luaL_setfuncs` walks
    /// the array until the name is null (`src/lauxlib.c:978-992`). A
    /// `Reg` literal with no fields is exactly that terminator.
    pub fn setFunctions(self: *State, entries: []const Reg) void {
        c.luaL_setfuncs(self.handle(), entries.ptr, 0);
    }

    /// One entry of a `luaL_Reg` array (`src/lauxlib.h:38-41`), which is
    /// upstream's own type and not a copy of it.
    ///
    /// A zeroed entry ends the array.
    pub const Reg = c.luaL_Reg;

    // -----------------------------------------------------------------------
    // Collector
    // -----------------------------------------------------------------------

    /// Run one full collection cycle.
    ///
    /// This is `lua_gc` with `LUA_GCCOLLECT` and no trailing argument
    /// (`src/lua.h:360`, `:333`), through `callGc`.
    pub fn collectGarbage(self: *State) void {
        _ = callGc(self.handle(), c.LUA_GCCOLLECT, .{});
    }

    /// Stop the collector on this state (`LUA_GCSTOP`, `src/lua.h:331`).
    ///
    /// This is the call that brackets a window in which a borrowed slice must
    /// stay put. A slice `errorMessage` or `toBytes` handed out is valid only
    /// until a collection reclaims or replaces the slot behind it, and stopping
    /// the collector is what makes "until later" a moment the caller chose.
    ///
    /// Upstream sets one bit and answers zero (`src/lapi.c:1180-1183`,
    /// `g->gcstp = GCSTPUSR`), so no cycle runs and no `__gc` metamethod fires
    /// while it is stopped. That is also why a collector stopped this way is
    /// not the refusal `isCollecting` and `garbageKilobytes` report as null:
    /// those are refused only while the collector has stopped *itself* or the
    /// state is closing, which upstream tests for separately
    /// (`GCSTPGC | GCSTPCLS`, `src/lapi.c:1175-1176`; the three bits are
    /// `src/lgc.h:213-216`). Here upstream answers, and `isCollecting` answers
    /// `false`.
    ///
    /// Nothing is released and nothing is remembered: whatever the caller was
    /// holding is still theirs to finish with, and only
    /// `restartGarbageCollector` hands collection back. A collector left
    /// stopped is a state that never collects on its own again.
    pub fn stopGarbageCollector(self: *State) void {
        _ = callGc(self.handle(), c.LUA_GCSTOP, .{});
    }

    /// Hand collection back after `stopGarbageCollector` (`LUA_GCRESTART`,
    /// `src/lua.h:332`).
    ///
    /// Upstream clears the bit and resets the debt to zero
    /// (`src/lapi.c:1184-1188`, `luaE_setdebt(g, 0); g->gcstp = 0`), and that
    /// is all it does: it runs no cycle and replays none of what was missed.
    /// The first collection after this one starts again, so a caller who
    /// stopped, allocated and restarted has made the allocations since the stop
    /// eligible for collection without having collected them yet.
    ///
    /// The stack is not touched, so a value pushed before the stop is still
    /// there; only the collector's own schedule was. Calling this on a
    /// collector that was already running resets its debt the same way and
    /// still collects nothing, and the call cannot fail either way.
    pub fn restartGarbageCollector(self: *State) void {
        _ = callGc(self.handle(), c.LUA_GCRESTART, .{});
    }

    /// Whether the collector is running on this state right now
    /// (`LUA_GCISRUNNING`, `src/lua.h:337`; `res = gcrunning(g)`, which is
    /// `gcstp == 0`, `src/lapi.c:1221-1222` and `src/lgc.h:216`).
    ///
    /// Null when upstream refuses the selector instead of answering it, which
    /// is the same refusal `garbageKilobytes` reports: `lua_gc` answers -1 for
    /// every selector while the collector has stopped itself or the state is
    /// closing (`src/lapi.c:1175-1176`). A caller can only be in one of those
    /// two windows - a `__gc` metamethod, which upstream runs from inside a
    /// cycle (`src/lgc.c:968-987`), or the pending finalizers `lua_close` runs
    /// through `luaC_freeallobjects` (`src/lgc.c:1529-1536`) - and in both a
    /// collection is in fact running, which upstream's own `gcrunning` would
    /// have denied, because the bit that refusal comes from means stopped to
    /// avoid re-entrant steps (`src/lgc.h:213-215`). So null here is upstream
    /// declining to answer, not a claim that nothing is collecting.
    ///
    /// A collector stopped through this module is not a refusal at all:
    /// `LUA_GCSTOP` sets its own bit (`src/lapi.c:1180-1182`), upstream answers
    /// zero, and this answers `false`.
    pub fn isCollecting(self: *State) ?bool {
        const running = counted(callGc(self.handle(), c.LUA_GCISRUNNING, .{})) orelse return null;
        return running != 0;
    }

    /// Memory the collector is managing, in kibibytes
    /// (`LUA_GCCOUNT`, `src/lua.h:334`).
    ///
    /// This selector takes no trailing argument and has no out-parameter, and
    /// the answer is what `lua_gc` returns: `res = cast_int(gettotalbytes(g) >>
    /// 10)` (`src/lapi.c:1193-1197`).
    ///
    /// Null when upstream refuses the selector. `lua_gc` answers -1 and takes
    /// no option at all when the collector has stopped itself or is closing
    /// the state (`src/lapi.c:1175-1176`), and a `__gc` metamethod - ordinary
    /// Lua code the collector runs - can ask from inside that window
    /// (`src/lgc.c:978-980`). A collector this module stopped is not that
    /// case: `stopGarbageCollector` sets a different bit
    /// (`src/lapi.c:1180-1182`).
    pub fn garbageKilobytes(self: *State) ?c_int {
        return counted(callGc(self.handle(), c.LUA_GCCOUNT, .{}));
    }

    /// Memory the collector is managing, in bytes: the whole number, not what
    /// is left of it below a kibibyte.
    ///
    /// Upstream splits that one number across two selectors and this is both
    /// halves of it: `LUA_GCCOUNT` (`src/lua.h:334`, `src/lapi.c:1193-1197`) is
    /// the count in kibibytes, and `LUA_GCCOUNTB` (`src/lua.h:335`,
    /// `src/lapi.c:1198-1201`) is the remainder, 0 to 1023.
    /// `src/lbaselib.c:210-215` is upstream composing them the same way for
    /// `collectgarbage("count")`, and `doc/manual.html:4228-4235` says what
    /// each selector is.
    ///
    /// Neither read allocates and neither collects, so the two are one number
    /// unless the caller allocates between them; stopping the collector first
    /// (`stopGarbageCollector`) makes it exactly one.
    ///
    /// Null when upstream refuses either selector, for the reason
    /// `garbageKilobytes` gives.
    pub fn garbageBytes(self: *State) ?usize {
        const state = self.handle();
        const kibibytes = counted(callGc(state, c.LUA_GCCOUNT, .{})) orelse return null;
        const remainder = counted(callGc(state, c.LUA_GCCOUNTB, .{})) orelse return null;
        return @as(usize, @intCast(kibibytes)) * 1024 + @as(usize, @intCast(remainder));
    }

    /// Run one step of garbage collection and answer whether it finished a
    /// cycle (`LUA_GCSTEP`, `src/lua.h:336`).
    ///
    /// The trailing argument is the step size, and upstream reads it as a
    /// `size_t` (`src/lapi.c:1204`), so this takes one and hands one. A
    /// narrower type would be read as a wider one, which is a value the
    /// upper half of the argument register happens to hold.
    pub fn stepGarbageCollector(self: *State, step: usize) bool {
        return callGc(self.handle(), c.LUA_GCSTEP, .{step}) != 0;
    }

    /// Tune one of the collector's six parameters (`LUA_GCPARAM`,
    /// `src/lua.h:340`, `:347-354`).
    pub fn setGarbageParameter(self: *State, parameter: GarbageParameter, value: c_int) void {
        _ = callGc(self.handle(), c.LUA_GCPARAM, .{ @backingInt(parameter), value });
    }

    /// Switch to generational collection (`LUA_GCGEN`, `src/lua.h:338`).
    ///
    /// This option takes no trailing argument. Lua 5.5 sets the three
    /// generational multipliers through `LUA_GCPARAM` instead, and both
    /// `src/lapi.c:1225-1228` and `doc/manual.html:12378-12380` are where
    /// upstream says so; `setGarbageParameter` is how this module sets them.
    pub fn setGenerational(self: *State) void {
        _ = callGc(self.handle(), c.LUA_GCGEN, .{});
    }

    /// Switch to incremental collection (`LUA_GCINC`, `src/lua.h:339`).
    ///
    /// As with `setGenerational`, this option takes no trailing argument
    /// (`src/lapi.c:1230-1233`): the pause, the step multiplier and the step
    /// size are `setGarbageParameter` parameters.
    pub fn setIncremental(self: *State) void {
        _ = callGc(self.handle(), c.LUA_GCINC, .{});
    }

    /// The six parameters `LUA_GCPARAM` accepts (`src/lua.h:347-354`).
    pub const GarbageParameter = enum(c_int) {
        minor_multiplier = c.LUA_GCPMINORMUL,
        major_to_minor = c.LUA_GCPMAJORMINOR,
        minor_to_major = c.LUA_GCPMINORMAJOR,
        pause = c.LUA_GCPPAUSE,
        step_multiplier = c.LUA_GCPSTEPMUL,
        step_size = c.LUA_GCPSTEPSIZE,
    };

    // -----------------------------------------------------------------------
    // Threads
    // -----------------------------------------------------------------------

    /// Push a new coroutine and return a non-owning view of it.
    ///
    /// `lua_newthread` (`src/lstate.c:278-302`) creates the thread, anchors it
    /// on this state's stack and gives it an empty stack of its own.
    ///
    /// A C pointer is nullable in this module and upstream never returns null
    /// here: the one allocation that can fail raises rather than answering
    /// (`src/lmem.c:209-210` into `luaM_error`, `src/lmem.h:17`), so this
    /// unwraps rather than maps a null it cannot observe.
    ///
    /// `ThreadRef` has no `deinit` because there is nothing this module may
    /// release: the thread belongs to the state, and closing it from here as
    /// well would run its pending `__close` metamethods twice. See `ThreadRef`.
    pub fn newThread(self: *State) ThreadRef {
        return .{ .raw = c.lua_newthread(self.handle()).? };
    }

    /// Push the thread on top of this state's stack.
    pub fn pushThread(self: *State) Index {
        return c.lua_pushthread(self.handle());
    }

    /// The status a thread was left in (`src/lua.h:314`): `LUA_OK` for a
    /// normal thread, `LUA_YIELD` while it is suspended, and an error code
    /// once it has stopped (`doc/manual.html:5793-5801`).
    ///
    /// A code this enum has no tag for is `error.UnexpectedStatus`, and not one
    /// of the tags above: a thread whose status this module cannot name has not
    /// been shown to have succeeded, and `ok` is the one answer a caller must
    /// never be handed by accident. This is the same tag `load` and `pcall`
    /// already give for a status they did not check (`statusOk`), so an
    /// unrecognised answer is one condition in this module rather than three.
    ///
    /// No valid provider reaches that arm. `lua_status` is `L->status` and
    /// nothing else (`src/lapi.c:1163-1165`), and every write to that field is
    /// one of the codes above: `LUA_OK` from `stack_init` and `resetthread`
    /// (`src/lstate.c:158`, `:244`), restored to `LUA_OK` when a suspended
    /// thread is resumed (`src/ldo.c:926`), `LUA_YIELD` from `luaD_yield`
    /// (`src/ldo.c:1021`), and an error code from `luaD_throwbaselevel` and
    /// `lua_resume` (`src/ldo.c:134`, `:992`), each of which takes it from
    /// `luaD_throw` (`src/ldo.c:126-127`). So this arm reports a provider that
    /// disagrees with the headers it was reached through; it is not a guess at
    /// what a code this module has no name for meant.
    pub fn statusOf(self: *const State) Error!Status {
        return Status.fromCode(c.lua_status(self.handle())) orelse error.UnexpectedStatus;
    }

    /// Whether a coroutine may yield on this thread right now
    /// (`src/lua.h:315`).
    pub fn isYieldable(self: *const State) bool {
        return c.lua_isyieldable(self.handle()) != 0;
    }
};

/// The one route to `lua_gc`, whichever of the two configurations this build
/// is, for the eleven calls the Collector section above makes.
///
/// `lua_gc` is a real C variadic (`src/lua.h:360`) and the two routes spell it
/// differently: the translation's own `extern fn` takes the trailing
/// arguments as promoted arguments, and the runtime-loaded dispatch takes them
/// as one final tuple. `runtime_loaded` is comptime, so this build resolves the
/// branch it has and never names the other one - the same rule `load` and
/// `version_ident` follow above.
///
/// `trailing` is that tuple: `.{}` for the selectors that take nothing, and one
/// or two promoted values for the ones that do. Nothing is reinterpreted
/// between the routes; the same value reaches the same argument register.
fn callGc(handle: ?*c.lua_State, what: c_int, trailing: anytype) c_int {
    if (comptime runtime_loaded) {
        return c.lua_gc(handle, what, trailing);
    }
    return @call(.auto, c.lua_gc, .{ handle, what } ++ trailing);
}

/// Upstream's answer for a selector `lua_gc` can refuse.
///
/// A count is never negative, so -1 is the one value that is not one: what
/// `lua_gc` returns for an option it does not know (`src/lapi.c:1244`), and
/// what it returns with no option taken at all when the collector is stopped
/// internally (`src/lapi.c:1175-1176`).
fn counted(value: c_int) ?c_int {
    return if (value < 0) null else value;
}

/// A coroutine of one `State`, and nothing that owns it.
///
/// `lua_newthread` (`src/lstate.c:278-302`) creates the thread, anchors it on
/// the parent's stack and initialises an empty stack for it; it does not close
/// anything, and the thread owns no resource of its own until something
/// to-be-closed is put on it. So this type deliberately has no `deinit`:
/// adding one would be a second close of a thread the parent already owns, and
/// `lua_closethread` runs the `__close` metamethods of whatever is left on the
/// thread's stack - twice, if both the parent and this view closed it.
///
/// Its lifetime is the lifetime of the state that made it, or until it is
/// popped off that state's stack. A caller who abandons a coroutine that holds
/// to-be-closed variables closes it itself through `c`, which is what
/// `coroutine.close` does inside Lua (`src/lcorolib.c:197-199`).
pub const ThreadRef = struct {
    raw: *c.lua_State,

    /// The thread itself, for anything the facade does not wrap.
    pub fn handle(self: ThreadRef) *c.lua_State {
        return self.raw;
    }

    /// Resume the coroutine, feeding it `nargs` values already on its stack.
    ///
    /// The name is escaped because `resume` is a Zig keyword, so a caller
    /// writes `thread.@"resume"(0)`.
    ///
    /// On success the number of results it produced is returned, and they are
    /// on the coroutine's own stack, which is where `lua_xmove` reached through
    /// `c` picks them up: a `ThreadRef` is not a `State`, so it cannot be an
    /// endpoint of `State.move`. On failure the error object is left on the
    /// coroutine's stack, and `LUA_YIELD` is reported as `Error.RuntimeError`,
    /// because from the resumer's side a yield and a failure are both "the
    /// call did not finish".
    pub fn @"resume"(self: ThreadRef, nargs: Index) Error!usize {
        var nresults: Index = 0;
        const status = c.lua_resume(self.raw, null, nargs, &nresults);
        if (status == c.LUA_YIELD) return error.RuntimeError;
        try statusOk(status);
        return @intCast(nresults);
    }

    /// Whether this coroutine can yield right now.
    pub fn isYieldable(self: ThreadRef) bool {
        return c.lua_isyieldable(self.raw) != 0;
    }
};

/// The status codes the C API returns, with the meaning each one has.
///
/// `Status` is the full set from `src/lua.h:48-53` plus the auxiliary library's
/// own `LUA_ERRFILE` (`src/lauxlib.h:27`), which upstream's manual lists in the
/// same section as the rest (`doc/manual.html:3472-3510`). It names codes and
/// not failures: `ok` and `yield` are what a healthy thread reports.
///
/// A code outside this set has no tag, and where that is decided differs by
/// which one is asking. `fromCode` answers `null` for it, because it is handed
/// a number a caller already holds. `statusOf` reads a status off a live
/// thread instead, and turns the same null into `error.UnexpectedStatus`
/// rather than returning a tag for a code it could not read.
pub const Status = enum(c_int) {
    ok = c.LUA_OK,
    yield = c.LUA_YIELD,
    runtime = c.LUA_ERRRUN,
    syntax = c.LUA_ERRSYNTAX,
    memory = c.LUA_ERRMEM,
    error_in_error = c.LUA_ERRERR,
    file = c.LUA_ERRFILE,

    /// The code behind a `Status`, or null when it is not one of these.
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

/// One status code, as one error tag.
///
/// This is the single funnel from a raw Lua status to a Zig error, and it maps
/// the whole namespace `Error` names: a code outside it becomes
/// `error.UnexpectedStatus`, because upstream documents that a call or a load
/// returns either `LUA_OK` or one of those, so that arm reports that the code
/// was not one of them rather than guessing what it meant.
///
/// Two of its arms are unreachable from its three callers and are kept anyway.
/// `LUA_YIELD` is handled before it is called (`resume` maps it to
/// `RuntimeError` itself), and `LUA_ERRFILE` can only come from
/// `luaL_loadfilex`, which none of them invokes. Both stay because the set is
/// the shared vocabulary and not a per-call list: a mapping written for the
/// codes the C API defines does not become a worse mapping when one of them
/// this module happens not to call today. Which call reaches what is named on
/// `Error`.
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