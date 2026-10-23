# Changelog

- Port to Zig 0.17.0.
- Nested consumer builds use their own cache and install prefix.
- The consumer step installs, rather than runs, targets requiring a non-native executor.
- System mode passes the selected pkg-config include path to header translation, so declarations and library come from one prefix.
- The consumer step runs only for native targets; otherwise it installs the consumer.
- Nested consumer builds relay target, CPU, optimize, linkage, runtime/system mode, jobs, and caller arguments, including `--provider` through both build stages.
- Fixed Zig 0.16 slice comparisons in `Platform.kind`.
- NetBSD and OpenBSD header translation now uses the target C preprocessor; macCatalyst uses upstream `LUA_USE_IOS`, so `os.execute` remains unavailable without adding readline.
- Runtime loading accepts Lua 5.5 providers and rejects LuaJIT 2.1.
- `garbageKilobytes()` and `garbageBytes()` expose distinct units; `garbageBytes()` is exact, and `isCollecting()` reports when Lua refuses the query.
- Shared builds use Lua's `lua_*`, `luaL_*`, and `luaopen_*` export namespaces on ELF; Windows also exports `lua_ident`, while Darwin and COFF retain internal symbols.
- Dynamic delivery is refused for `wasm32-wasi`; static delivery remains available.
- Added a Zig module with a typed Lua state/thread facade, translated C declarations, and an explicit runtime-provider route.
- Added Lua 5.5.1 packaging for the library, interpreter, compiler, headers, pkg-config metadata, and man pages; shared library soname is `liblua.so.55`.
