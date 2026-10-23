# Fork notes

## Source deviations

None. Files under `src/` and `doc/`, the upstream makefiles, and upstream `README` are unchanged.

The release tarball has no upstream test suite. Its `test` target runs `lua -v`. The fork does not fetch a separate test tree.

## Build graph deviations

- `build.zig` replaces upstream's Makefile build. It compiles the same C source closure and the upstream `lua` and `luac` program entry points.
- Target configuration comes from the target, not the build host. The same `LUA_USE_*` macros reach C compilation and C translation.
- The package adds a typed Zig facade, raw translated-C access, optional runtime loading, and optional system-library mode.
- Static delivery is the default. Dynamic delivery adds `liblua.so.55.5.1` with soname `liblua.so.55`. Runtime loading is independent of delivery linkage.
- The build writes `lib/pkgconfig/lua.pc`, an ELF version map, and a runtime dispatch when runtime loading is enabled. It generates nothing under `src/` or `doc/`.
- NetBSD and OpenBSD use the target C compiler to preprocess the aggregate header before Aro translates it. Their bundled C headers contain constructs Aro cannot parse directly.

## Runtime provider boundary

A runtime provider must match the headers' Lua version, numeric types, public structure layouts, configuration macros, allocator contract, and bytecode format. Matching symbol names alone does not prove ABI compatibility. Lua allocations must remain paired with the allocator and state that own them.

The loader checks the provider's Lua version and identity and tests an integer round-trip. It cannot establish structure layout or bytecode compatibility. It keeps `lua_ident` as a pointer into the loaded provider rather than copying its value. LuaJIT 2.1 reports API version 501 and is refused because it is not compatible with the Lua 5.5 interface.

## Platform boundaries

- `wasm32-wasi` is refused for every linkage. Upstream's `os.tmpname` implementation requires `L_tmpnam` and `mkstemp`, which this toolchain's WASI libc does not provide.
- macCatalyst uses upstream's `LUA_USE_IOS` path. `os.execute` is unavailable there; the other standard-library functions remain available.
- Darwin avoids `LUA_USE_MACOSX`, which would make readline a link-time dependency. Readline remains optional and is loaded at runtime where configured.
- Shared delivery requires a dynamic linker. Targets without one do not receive a substituted static archive.
- ELF shared objects use a version map for Lua's public symbol namespaces. Darwin and COFF do not use that map, so symbol visibility differs from ELF; a resolved symbol is not proof that it is public API.
