// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.
//
//! Lua's side of the runtime loader: the names its synchronization binding has,
//! what it requires of a provider beyond resolving its symbols, and what the
//! external ABI boundary for this provider actually is.
//!
//! Everything else about the runtime route is generic. `runtime/loader.zig` is
//! the state machine and the platform layer; `runtime/generate.zig` builds the
//! dispatch from whatever the translation step actually produced;
//! `runtime/graph.zig` wires them together. This file is what makes them Lua's,
//! and it is the file another SDK replaces.
//!
//! ## What a provider must be
//!
//! All 157 declarations of `zig/translate.h`: the 98 functions of `src/lua.h`,
//! the 48 of `src/lauxlib.h`, the 10 of `src/lualib.h`, and the exported data
//! object `lua_ident` (`src/lua.h:157`). There is no config-gated entry point
//! in this configuration - nothing in the three headers sits behind a
//! `LUA_USE_*` or `LUA_COMPAT_*` macro - so `provider_optional` and
//! `provider_excluded` in `runtime/graph.zig` are both empty and a provider
//! that does not export the whole set is refused rather than half used.
//!
//! The C library's own `stdio` surface, which reaches the translation only
//! because `src/lauxlib.h:13` includes `<stdio.h>` for `FILE *` in
//! `luaL_Stream`, is classified as noise in `runtime/graph.zig` and is not in
//! the table. It is not part of what a Lua provider owes.
//!
//! ## The ABI boundary, stated honestly
//!
//! The supported external ABI family is **Lua 5.5** - `LUA_VERSION_NUM` 505 -
//! built from these three headers with upstream's default numeric
//! configuration. That is a narrower claim than "a shared object that exports
//! these names", and the difference is real:
//!
//!   * `lua_Integer` is 64-bit (`LUA_INT_LONGLONG`, `src/luaconf.h:136`) and
//!     `lua_Number` is `double` (`LUA_FLOAT_DOUBLE`, `src/luaconf.h:137`), so
//!     `lua_pushinteger` takes a 64-bit integer and `lua_pushnumber` takes a
//!     `double`. A provider built with `LUA_32BITS` or with an explicit
//!     `LUA_INT_TYPE` passes different widths through the same symbol names and
//!     is a different ABI under the same header names.
//!   * `lua_State` is opaque and `luaL_Buffer` (`src/lauxlib.h:185-195`) has a
//!     fixed layout with a 1024-byte inline area
//!     (`LUAL_BUFFERSIZE`, `src/luaconf.h:724`: `16 * sizeof(void*) *
//!     sizeof(lua_Number)`), so a provider compiled with a different
//!     `lua_Number` disagrees about that struct's size and about every offset
//!     the C code reads through it.
//!   * The allocator is the provider's. `luaL_newstate` (`src/lauxlib.c:1197`)
//!     calls `lua_newstate(luaL_alloc, NULL, ...)` and `luaL_alloc`
//!     (`src/lauxlib.c:1062`) calls libc's `realloc` and `free` directly.
//!     Nothing in this SDK can observe, bound or account for those allocations:
//!     a Zig allocator is not in the path, and a test framework cannot supply a
//!     leak oracle for memory a third-party allocator owns.
//!   * `lua_CFunction`, `lua_KFunction`, `lua_Reader`, `lua_Writer`, `lua_Alloc`,
//!     `lua_WarnFunction` and `lua_Hook` are function-pointer types crossing
//!     the boundary in both directions. A callback built against this
//!     translation is called by the provider's own C with the provider's own
//!     calling convention.
//!
//! **LuaJIT is a different ABI and is refused.** LuaJIT 2.1 implements the Lua
//! 5.1 API: its `lua_version` answers 501, its `lua_Integer` is its own type,
//! and its `luaL_Buffer` and error-code set differ. It has its own SDK in this
//! workspace, `luajit`, which publishes its own header translation and its own
//! table. Pointing this loader at a LuaJIT object is refused by the version
//! check below rather than half working.
//!
//! Resolving the symbols and translating the header is the boundary. They are
//! not proof that a provider is compatible, and this file does not pretend to
//! add more than it checks. What is checked at load time, before anything is
//! published:
//!
//!   * `lua_version` answers with this header's `LUA_VERSION_NUM`. That is the
//!     ABI *family* check: it is what separates 5.5 from 5.4, from 5.3 and from
//!     LuaJIT's 5.1.
//!   * `luaL_newstate` returns a state and `lua_close` releases it. That
//!     exercises the provider's allocator and its teardown path, and it closes
//!     the state through the same table entry that created it, so nothing here
//!     ever creates a state with one provider and destroys it with another.
//!   * A fresh state has an empty stack, and an integer above 2^53 round-trips
//!     through `lua_pushinteger` and `lua_tointegerx` as an integer. A
//!     provider whose `lua_Integer` is 32- or 53-bit cannot do that, so this is
//!     the scalar-width check the version number alone does not make.
//!   * `lua_ident` resolves to a live address whose bytes begin with
//!     `$LuaVersion:`, which is how `src/lapi.c:35-37` spells it. Exported data
//!     arrives as the provider's address, never as a copy, so this is also the
//!     check that the data half of the table is wired to something real.
//!
//! What is deliberately *not* called here is `luaL_checkversion_`
//! (`src/lauxlib.h:46`), which is upstream's own version-and-size check. It
//! raises a Lua error rather than returning one, and a Lua error outside a
//! protected call goes to the panic handler, which aborts the process. A loader
//! that has to answer `ValidationFailed` cannot use a check whose failure mode
//! is `abort`, so the facts it would have checked - the version number and the
//! scalar widths - are checked here instead, in a form that returns.
const std = @import("std");

const rt = @import("rt");

/// The synchronization this loader calls, bound by exact name.
///
/// The names below are `runtime/sync.c` compiled with
/// `RT_SYNC_PREFIX=lua_rt`, which is what `runtime/graph.zig` passes. Two
/// spellings of that prefix have to agree: this file names the symbols, and
/// graph.zig defines the macro. A build where they disagree does not link, and
/// that is the whole error report: there is no runtime path that could hide it.
///
/// The core in `runtime/loader.zig` never names a symbol of its own, which is
/// what lets two SDKs, or two configurations of one SDK, hold their own loader
/// state in one process without sharing any of it.
pub const Sync = struct {
    extern fn lua_rt_lock() void;
    extern fn lua_rt_unlock() void;
    extern fn lua_rt_wait() void;
    extern fn lua_rt_broadcast() void;
    // `unsigned long long`. Declared as u64, which is the same type in every
    // ABI this SDK targets: 64-bit on x86_64, aarch64, riscv64 and wasm32.
    extern fn lua_rt_thread_self() u64;

    pub fn lock() void {
        lua_rt_lock();
    }
    pub fn unlock() void {
        lua_rt_unlock();
    }
    pub fn wait() void {
        lua_rt_wait();
    }
    pub fn broadcast() void {
        lua_rt_broadcast();
    }
    pub fn threadSelf() u64 {
        return lua_rt_thread_self();
    }
};

/// The first eleven bytes `src/lapi.c:35-37` writes at the start of `lua_ident`,
/// past the `$LuaVersion: ` tag with no space before it.
const ident_prefix = "$LuaVersion:";

/// `2^53 + 1`. `double` cannot hold it, so an integer that comes back with this
/// value and `isnum` set is evidence that `lua_Integer` is at least 64 bits
/// wide, which `LUA_INT_LONGLONG` (`src/luaconf.h:136`) makes it.
const wide_integer: i64 = 9007199254740993;

/// The loader's configuration for this SDK, given the dispatch that owns the
/// table.
///
/// `dispatch` is the generated module, passed as a type by the dispatch itself
/// so that this file never has to import it. The direction is one-way on
/// purpose: the descriptor knows what the loader needs, the dispatch knows what
/// the header said, and neither imports the other.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Named in the pre-load panic, so the message says which library was
        /// reached for before it was loaded.
        pub const library_name = "lua";

        /// The table the generated dispatch declares, and the symbols it needs
        /// to fill it. Both come from the translated headers, not from this file.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// The project's namespaced synchronization binding.
        pub const sync = Sync;

        pub fn tablePtr() *table {
            return dispatch.tablePtr();
        }

        pub fn ready() *rt.Ready {
            return &dispatch.ready;
        }

        pub fn assign(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assign(index, dst, address);
        }

        pub inline fn assignOptional(comptime index: usize, dst: *table, address: *const anyopaque) void {
            dispatch.assignOptional(index, dst, address);
        }

        pub inline fn assignMissing(comptime index: usize, dst: *table) void {
            dispatch.assignMissing(index, dst);
        }

        /// The library-specific checks, run after every symbol resolved and
        /// before anything is published.
        ///
        /// A non-null answer is `ValidationFailed` and the candidate is closed
        /// without being published. Every check here is one whose failure this
        /// code can observe; see the module comment for what is deliberately
        /// not called and why.
        pub fn validate(dst: *const table) ?[]const u8 {
            // `lua_version` ignores its argument (`src/lapi.c:152-155`), so
            // null is what upstream's own definition accepts, and asking it
            // before a state exists is the cheapest possible way to learn which
            // API family the provider implements.
            const family = dst.lua_version(null);
            const expected: f64 = @floatFromInt(dispatch.LUA_VERSION_NUM);
            if (family != expected) {
                // The numbers go to the diagnostic stream rather than into the
                // returned text: `validate` has no allocator and the loader
                // reports whatever string it is given.
                std.debug.print(
                    "lua: provider reports lua_version {d}, this SDK's headers " ++
                        "describe {d}; they are different external ABIs\n",
                    .{ family, expected },
                );
                return "this provider implements a different Lua API family " ++
                    "than the one this SDK's headers describe";
            }

            // Aro represents the exported array as an @extern C pointer. The
            // table stores that live address, not a pointer to a copied pointer.
            if (std.mem.eql(u8, dst.lua_ident[0..ident_prefix.len], ident_prefix) == false) {
                return "lua_ident does not begin with the $LuaVersion: tag " ++
                    "src/lapi.c:35-37 writes, so this provider is not the " ++
                    "library these headers describe";
            }

            // Create and destroy one state through this same table. That is the
            // allocator and teardown check, and doing the close here rather than
            // at process exit is what keeps the check from leaking if it fails.
            const state = dst.luaL_newstate() orelse return
                "luaL_newstate returned null, so this provider's allocator could " ++
                "not satisfy a fresh state";
            defer dst.lua_close(state);

            // A state that has just been created has an empty stack
            // (`src/lstate.c:341-393` initialises it with nothing pushed). A
            // provider that disagreed here would be describing a different
            // state structure under the same name.
            if (dst.lua_gettop(state) != 0) return
                "a freshly created state is not at stack position zero, so this " ++
                "provider's state structure is not the one these headers describe";

            // The scalar-width check. Pushed and read back through the provider,
            // so it is a statement about the provider rather than about this
            // translation.
            dst.lua_pushinteger(state, wide_integer);
            var isnum: c_int = 0;
            const seen = dst.lua_tointegerx(state, -1, &isnum);
            if (isnum == 0 or seen != wide_integer) return
                "lua_Integer is not 64 bits wide in this provider, so the " ++
                "integer ABI these headers describe is not the one it provides";
            // `lua_pop` is a macro (`src/lua.h:396`) expanding to
            // `lua_settop(L, -(n)-1)`; there is no such symbol to call.
            dst.lua_settop(state, -2);

            return null;
        }
    };
}