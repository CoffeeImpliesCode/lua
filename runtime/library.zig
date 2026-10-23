// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.
//
//! Lua provider descriptor for the Lua 5.5 default numeric ABI.
//! Requires all 157 translated Lua exports; checks the API family, wide-integer behavior, state lifecycle, and `lua_ident`.
//! Lua owns its allocations; callbacks cross the boundary with `callconv(.c)`.
//! LuaJIT's Lua 5.1 ABI is rejected by the version check.
const std = @import("std");

const rt = @import("rt");

/// Lua's namespaced synchronization binding, matching the prefix compiled into `sync.c`.
/// The loader core does not declare these symbols itself.
pub const Sync = struct {
    extern fn lua_rt_lock() void;
    extern fn lua_rt_unlock() void;
    extern fn lua_rt_wait() void;
    extern fn lua_rt_broadcast() void;
    // Zig's `u64` matches the `unsigned long long` thread-id ABI.
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

/// Required prefix in the provider's exported `lua_ident` bytes.
const ident_prefix = "$LuaVersion:";

/// Exact integer above 2^53 used to detect narrower provider integer types.
const wide_integer: i64 = 9007199254740993;

/// Loader configuration for the generated dispatch table.
/// The comptime dispatch type keeps this descriptor independent of its module.
pub fn Config(comptime dispatch: type) type {
    return struct {
        /// Name used in pre-load diagnostics.
        pub const library_name = "lua";

        /// Generated dispatch table and required export list.
        pub const table = dispatch.Table;
        pub const symbols = dispatch.symbols;
        pub const optional_symbols = dispatch.optional_symbols;

        /// Namespaced C synchronization functions.
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

        /// Check API family, exported identity, state lifecycle, and integer width before publication.
        /// Return a reason for `ValidationFailed`, or null when compatible.
        pub fn validate(dst: *const table) ?[]const u8 {
            // `lua_version` ignores its argument; null is accepted by upstream.
            const family = dst.lua_version(null);
            const expected: f64 = @floatFromInt(dispatch.LUA_VERSION_NUM);
            if (family != expected) {
                // Validation has no allocator, so diagnostics go to stderr.
                std.debug.print(
                    "lua: provider reports lua_version {d}, this SDK's headers " ++
                        "describe {d}; they are different external ABIs\n",
                    .{ family, expected },
                );
                return "this provider implements a different Lua API family " ++
                    "than the one this SDK's headers describe";
            }

            // Translation exposes the exported `lua_ident` array by its live address.
            if (std.mem.eql(u8, dst.lua_ident[0..ident_prefix.len], ident_prefix) == false) {
                return "lua_ident does not begin with the $LuaVersion: tag " ++
                    "src/lapi.c:35-37 writes, so this provider is not the " ++
                    "library these headers describe";
            }

            // Create and close through one provider to test allocation and teardown without leaking.
            const state = dst.luaL_newstate() orelse return
                "luaL_newstate returned null, so this provider's allocator could " ++
                "not satisfy a fresh state";
            defer dst.lua_close(state);

            // Lua initializes a new state's stack empty; a mismatch indicates an incompatible state layout.
            if (dst.lua_gettop(state) != 0) return
                "a freshly created state is not at stack position zero, so this " ++
                "provider's state structure is not the one these headers describe";

            // Round-trip an integer beyond `double`'s exact integer range.
            dst.lua_pushinteger(state, wide_integer);
            var isnum: c_int = 0;
            const seen = dst.lua_tointegerx(state, -1, &isnum);
            if (isnum == 0 or seen != wide_integer) return
                "lua_Integer is not 64 bits wide in this provider, so the " ++
                "integer ABI these headers describe is not the one it provides";
            // `lua_pop` is a macro; call its `lua_settop` expansion directly.
            dst.lua_settop(state, -2);

            return null;
        }
    };
}
