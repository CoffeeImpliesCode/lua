# Lua

Lua 5.5.1 (released 2026-07-24), packaged as an embeddable Zig SDK.
It provides the Lua C API, a typed Zig facade, and the `lua`/`luac` tools.
Minimum Zig version: 0.17.0.

## Source deviations

The 75 imported files in `src/`, `doc/`, root `Makefile`, and upstream `README` are unchanged. Fork-authored Zig code provides the typed facade and runtime loader; upstream C sources are not patched. Imported-file digests are in `UPSTREAM.sha256`; release identity is in `UPSTREAM.md`.

## Build deviations

- `build.zig` replaces upstream's Makefile for bundled builds. It builds the C library, `lua`, and `luac`; `luac` always links statically.
- The package adds raw translated headers, optional runtime loading, and system-library mode.
- Bundled builds default to static linkage. Dynamic builds generate a shared-library export map on ELF, a module definition file on Windows, and `lib/pkgconfig/lua.pc`.
- NetBSD and OpenBSD preprocess `zig/translate.h` with the target C compiler before Aro translates it.

## Support matrix

The `check` step configures compile-only targets `x86_64-linux-gnu`, `aarch64-linux-gnu`, `riscv64-linux-gnu`, `aarch64-macos-none`, and `x86_64-windows-gnu`.

| Target | Configuration and boundary |
|---|---|
| Linux | `LUA_USE_LINUX`; POSIX, `dlopen`, and runtime readline lookup. |
| Darwin | POSIX and `dlopen`; avoids a readline link dependency. Shared objects expose internal symbols as well as the public API. |
| macCatalyst | `LUA_USE_IOS`; `os.execute` is unavailable. |
| Windows | Uses upstream's `_WIN32` path; shared builds define `LUA_BUILD_AS_DLL` and export `lua_ident` through a module definition file. |
| Other Unix | POSIX, `dlopen`, and runtime readline lookup. |
| NetBSD, OpenBSD | The target C compiler preprocesses the aggregate header before Aro. |
| `wasm32-wasi` | Refused for every linkage: upstream `os.tmpname` requires `mkstemp` and `L_tmpnam`, absent from Zig 0.17.0's WASI libc. |

Dynamic delivery requires a target dynamic linker. The build does not substitute a static archive when one is unavailable.

## Consumption

### `build.zig.zon` dependency

For a local checkout, add:

```zig
.dependencies = .{
    .lua = .{ .path = "../lua" },
},
```

### Module and artifacts

The module and bundled C artifact are both named `lua`:

```zig
const dep = b.dependency("lua", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("lua", dep.module("lua"));
const liblua = dep.artifact("lua"); // bundled mode
```

`@import("lua")` provides the typed facade; its `c` field exposes the translated headers. Bundled installs provide `liblua.a` or, on ELF, `liblua.so.55.5.1` (soname `liblua.so.55`), the five public headers, `bin/lua`, `bin/luac`, and `lib/pkgconfig/lua.pc`.

### Build options

- `-Dlinkage=static|dynamic`: bundled mode defaults to `static`; system mode defaults to `dynamic`.
- `-Druntime=true`: route native calls through a generated dispatch, independent of linkage. Load an explicit provider with `lua.load(.{ .path = "/path/to/liblua.so" })` or `lua.load(.{ .system = "liblua.so.55" })`; requests do not fall back or unload.
- `-Dsystem=true` or `-fsys=lua`: use installed headers and `liblua` instead of bundled sources. System mode installs no library or Lua programs.
