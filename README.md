# lua

Lua 5.5.1 — the embeddable scripting language — as a complete standalone Zig
SDK: the whole interpreter, all ten standard libraries, the standalone
`lua` and `luac` programs, the public C headers, a typed Zig surface, the raw
translated C route and an optional runtime-loading route, built from the
official release sources with no autotools, no CMake and no build-time
download.

* Upstream: the `lua-5.5.1.tar.gz` release, 2026-07-24, sha256
  `1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce` —
  see [`UPSTREAM.md`](UPSTREAM.md).
* Native source: unmodified. Every one of the 75 upstream files is recorded by
  digest in [`UPSTREAM.sha256`](UPSTREAM.sha256).
* Licence: MIT, Copyright (C) 1994-2026 Lua.org, PUC-Rio, for Lua itself; MIT
  for this fork's own files — see [`NOTICE.md`](NOTICE.md) and
  [`FORK-LICENSE.md`](FORK-LICENSE.md).
* Upstream's own README is preserved verbatim in
  [`README.upstream.md`](README.upstream.md) and in `doc/readme.html`, and is
  reproduced at the end of this file.
* **Three of the four runtime/linkage combinations have been built and run**
  on this host. Each row of the observed table below names what was run and
  what came out; every gate not in that table is still
  `PENDING-VERIFICATION`, and the driver owns those results.

## Native-source deviations

**None.** Every file under `src/` and `doc/`, both upstream `Makefile`s and
`README` are byte-identical to the release tarball. No portability patch, no
reformat, no `#if` added around a platform workaround.

That is a checkable claim rather than an assertion:

```sh
sha256sum -c UPSTREAM.sha256          # the bytes
tools/check-provenance.sh             # the bytes, the exact file set, the notice
```

`tools/check-provenance.sh` also rejects a file that appears under `src/` or
`doc/` without a recorded digest, which a checksum run alone cannot see. Any
future native edit has to move those digests, add a per-file record to
`NOTICE.md` and a numbered entry to [`CHANGELOG.md`](CHANGELOG.md) in the same
change, and needs an observed failure to justify it.

Two upstream facts that shape this SDK, both read out of the source rather than
assumed:

* **The tarball carries no test suite.** `src/Makefile:69-70` defines
  `test:` as `./$(LUA_T) -v`, and `doc/readme.html` says the same in prose. The
  SDK therefore does not claim to ship, build or run an upstream suite, and no
  build step fetches one: Lua's test library lives in the working repository,
  is a different source tree, and has no recorded digest here.
* **No native source is generated at build time.** There is no configure step
  and no generated header to regenerate per target. `src/ljumptab.h`, the
  interpreter dispatch table, is a checked-in source file carrying the `sed`
  command upstream uses to refresh it (`src/ljumptab.h:21-25`). The build graph
  does generate three files, none of which is a second source of truth for the
  C: `lib/pkgconfig/lua.pc`, the ELF version script, and — only under
  `-Druntime=true` — the dispatch, which is generated from the translation
  this same build just produced.

## Native-build deviations

What the compiled package does that upstream's two `Makefile`s do not. Each is a
fork decision with a stated reason; none of them changes an algorithm.

* **Zig builds it; upstream's build system is unused.** `build.zig` compiles the
  same closure `src/Makefile` names: the 20 core translation units of `CORE_O`,
  the 12 units of `LIB_O` that carry the ten standard libraries, the auxiliary
  library and `linit.c`, and the two program mains `lua.c` and `luac.c` — 34
  translation units in all. No make, no CMake, no autotools, and no download at
  build time.
* **Two delivery linkages.** `-Dlinkage=static` (default) produces
  `liblua.a`; `-Dlinkage=dynamic` produces `liblua.so.55.5.1` with the soname
  `liblua.so.55` and the `liblua.so` linker symlink. The 55 is the one ABI
  number upstream states anywhere — `src/Makefile:132-135` builds `lua55.dll`
  for mingw — and upstream's `Makefile` builds an archive only, so static is the
  preserved default and shared is the added variant. A requested delivery is
  never substituted: `deliveredLinkage` refuses a target whose OS has no
  dynamic linker at all rather than hand back an archive under the name that
  was not asked for. That is a general property and not this build's WASI
  story — `wasm32-wasi` is refused earlier and for every linkage, so it never
  reaches a delivery decision at all; see "The cross-target matrix" below.
* **The exported surface is Lua's public namespaces, where the platform allows
  it.** The three public headers declare 156 functions (98 `LUA_API` in
  `lua.h`, 47 `LUALIB_API` in `lauxlib.h`, 1 `LUALIB_API` plus 10 `LUAMOD_API`
  in `lualib.h`) and one data object, `lua_ident` (`src/lua.h:157`). On ELF a
  generated version script (`build.zig`'s `setVersionScript`) exports the three
  namespaces `lua_*`, `luaL_*` and `luaopen_*` and marks everything else
  `local`, so there is no hand-maintained function catalogue that could fall out
  of step with the headers, and the data symbol rides in with the namespaces
  rather than being listed separately. On Windows, `LUA_BUILD_AS_DLL` gives
  `LUA_API` its `__declspec(dllexport)` and a generated module definition file
  carries the one entry the macro does not cover, `lua_ident DATA`, because
  `src/lua.h:157` declares that object without `LUA_API`. There is no Mach-O
  equivalent this build can rely on and `LUA_API` is plain `extern` everywhere
  except Windows (`src/luaconf.h:315`), so on Darwin and COFF the shared object
  also exports Lua's internal symbols. That is a capability boundary, not an
  oversight, and `zig build` prints the difference on its configure line.

  Observed on the delivered ELF object: `nm -D` reports 157 defined dynamic
  symbols — 99 `lua_` (the 98 `LUA_API` plus `lua_ident`), 48 `luaL_` (47 in
  `lauxlib.h` plus the one `LUALIB_API` in `lualib.h`) and 10 `luaopen_` — and
  no `luaS_*`, `luaC_*`, `luaH_*` or any other internal name.
* **The full installed closure, from one writer.** `lib/liblua.a` or the three
  shared names; `include/` with the five public headers (`lua.h`,
  `luaconf.h`, `lualib.h`, `lauxlib.h`, `lua.hpp`), flat;
  `lib/pkgconfig/lua.pc`, the only generated file that is installed,
  relocatable
  through `prefix=${pcfiledir}/../..`; `bin/lua` and `bin/luac`;
  `share/man/man1/{lua,luac}.1`; and `share/licenses/lua/` holding
  `readme.html` and `lua.h` — the two upstream files that actually carry the
  MIT text and the Lua.org notice, since the tarball ships no standalone
  `LICENSE` — together with the seven fork records `README`, `NOTICE.md`,
  `FORK-LICENSE.md`, `UPSTREAM.md`, `UPSTREAM.sha256`, `FORK-NOTES.md` and
  `CHANGELOG.md`. Nine files in all, which is exactly `licence_records` in
  `build.zig:546-556`; `README.upstream.md` is a repository copy of bytes
  `README` already carries and is deliberately not installed a second time
  under another name. Upstream's `Makefile` installs all but the `.pc` file;
  `make pc` only echoes the values one would contain (`Makefile:96-101`).
  Under `-Dlinkage=dynamic` the interpreter links the shared object while
  `luac` stays statically linked, as upstream requires.
* **A typed Zig surface beside the raw one.** `zig/root.zig` publishes a
  documented facade over the same library; the translated headers are reached
  as `c` on that module rather than registered as a module of their own.
  Documented in [`README.zig.md`](README.zig.md).
* **Optional runtime loading.** `-Druntime=true` selects a load-at-runtime
  route with explicit `path` or `system` selection, one process-lifetime table,
  no fallback and no automatic retry; the linked route stays direct. Orthogonal
  to `-Dlinkage`.
* **Optional system mode.** `-Dsystem=true` (default false; `-fsys=lua`
  overrides it) builds against an installed Lua instead of this source, and
  installs nothing and builds neither program. The `consumer` step resolves the
  same mode and forwards it into the nested build, so `zig build consumer
  -Dsystem=true` reaches the installed library instead of quietly proving the
  bundled graph a second time. On this host that route **refuses**: there is no
  Lua 5.5 header set and no `-llua` to bind to, so the missing family is named
  and the build stops. That is the boundary, stated rather than papered over —
  the driver's receipt for the refusal is
  `review-contract-probes/evidence/before-20261004T200332Z/index.json`, taken
  through the same mode on the consumer package directly.
* **NetBSD and OpenBSD read the C library through the compiler, not through
  Aro.** `zig translate-c` preprocesses and parses with Aro, and three header
  behaviours in Zig 0.16.0's bundled BSD C libraries defeat it: NetBSD routes
  `__END_DECLS` through `_Pragma`, OpenBSD 32-bit declares `size_t` twice to two
  different types, and OpenBSD on MIPS64 reaches an `#error` in
  `mips64/endian.h` for want of `__MIPSEL__`/`__MIPSEB__`. Those two families
  therefore run the target's own C preprocessor (`zig cc -E -dD`) over
  `zig/translate.h` and hand Aro the result — the front end ERFA already uses.
  Nothing else changes: the aggregate, the public API and constant set,
  `c_flags`, the platform macros, the 32-unit C closure, the installed headers
  and the delivery options are the same, and no predefine was invented. The
  extra step is named `preprocess lua translate.h` and appears in `--summary all`
  for NetBSD and OpenBSD targets only, so that name appearing is the cheapest
  check that the route was selected.
* **Per-target platform configuration.** `LUA_USE_*` is chosen from the target
  being built and handed to every C compile line *and* to the translation, so
  declarations and compiled code cannot disagree: Linux gets `LUA_USE_LINUX`
  (POSIX + `dlopen` + a `libreadline.so` default); Darwin gets `LUA_USE_POSIX`
  and `LUA_USE_DLOPEN` but deliberately **not** `LUA_USE_MACOSX`, because
  `src/luaconf.h:79-83` would turn that into a link-time `-lreadline`
  requirement; macCatalyst gets upstream's own `LUA_USE_IOS`, which
  `src/luaconf.h:86-89` expands to exactly the same `LUA_USE_POSIX` and
  `LUA_USE_DLOPEN` pair and to nothing else — `src/loslib.c:133-140` then answers
  `system()` with `((cmd) == NULL ? 0 : -1)` under upstream's own comment, so
  **no readline dependency is added** and `os.execute` is the one
  standard-library function this build cannot provide on that target, answering
  `nil, "exit", -1` and `false` where upstream says there is no shell; other
  Unix gets POSIX, `dlopen` and the readline default; Windows gets nothing and
  reaches upstream's own `_WIN32` branches. WASI's row is recorded in that same
  table — nothing, so the "no dynamic loading" fallbacks in `src/loadlib.c` and
  `src/liolib.c` — and is kept because it is the answer that has to be right if
  the refusal ever goes away; today
  `addGraph` refuses that target before the table is consulted. `LUA_USE_C89`,
  `LUA_32BITS`, `LUA_INT_TYPE`, `LUA_FLOAT_TYPE`,
  `LUA_USE_APICHECK` and every `LUA_COMPAT_*` are never defined, and the C
  level is pinned to `-std=gnu99` as upstream's own `src/Makefile:9` does.
* **One version, three places.** `build.zig` refuses to configure unless
  `build.zig.zon`'s `.version` equals the 5.5.1 read out of `src/lua.h:20-22`,
  so the package manifest, the `lua.pc` `Version:` field and the shared
  object's file name cannot describe three different releases.

### History of these deviations

The deviations above are the current state. [`CHANGELOG.md`](CHANGELOG.md)
numbers each one with the date it landed — all of them in the 2026-10-04
contract migration that created this SDK — and [`FORK-NOTES.md`](FORK-NOTES.md)
records the evidence and the open questions behind them.

## Build, run and test matrix

### What has been observed

Three of the four runtime/linkage combinations have been built and run on this
host, against the artifacts this graph itself produces, and the consumer package
has been run as a nested build in all four. The first three commands are the
build graph's own steps — `test`, `smoke`, and the default `install` step — run
with the driver's scratch prefix rather than `zig-out`; the fourth is
`zig build consumer`:

| Configuration | What was run | Observed |
|---|---|---|
| Linked, static delivery | `zig build smoke test -Dlinkage=static` | **9/9 build steps, 19/19 tests passed.** The smoke matched every expected answer — arithmetic, integer wraparound, float division, byte-exact strings with an embedded NUL, `string.format`, `utf8.char`, a Zig callback reached from Lua, both error statuses with their messages, `luaL_len` and a raw variadic `lua_pushfstring` |
| Shared delivery | `zig build install -Dlinkage=dynamic` | **26/26 steps succeeded.** `liblua.so.55.5.1` with soname `liblua.so.55`, five headers, `lua.pc`, `bin/lua`, `bin/luac`, both man pages and the nine licence records; 157 dynamic exports and no internal symbol |
| Runtime-loaded, static delivery | `zig build smoke test -Druntime=true` with an explicit provider | **9/9 build steps, 19/19 tests passed** against an installed `liblua.so.55.5.1` named explicitly: the whole test binary and the smoke ran through the dispatch, and the provider's own `lua_ident` printed as `$LuaVersion: Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio …` rather than a constant compiled into the program |
| Consumer package, nested | `zig build consumer` over the four linkage/route combinations, each run twice — once leaving the options to their defaults and once naming `-Dtarget`, `-Dcpu`, `-Dlinkage`, `-Druntime` and `-fno-sys=lua` — plus one row with no provider at all | **9/9 cases as expected.** Eight exited 0, six build steps for a static delivery and seven for the shared one, each printing the consumer program's own `every answer matched the documented value`. The ninth exited 1 with `error: NoProviderConfigured`, which is the refusal the program is written to print |

The provider in the third row is a real `liblua.so.55.5.1` built by this graph
from these sources and installed; it is named explicitly, on the command line
or in `LUA_TEST_PROVIDER`. Nothing was fetched, and no linked copy stood in
for it.

The fourth row is about the graph rather than the library. What the driver read
off the nested `zig build run` command line in each of the eight passing cases:
`-Dcpu=baseline` beside `-Dtarget=x86_64-linux-gnu`, both equal to what the
caller named; `-fno-sys=lua`, so the mode is the caller's and not the nested
graph's own default; `-j8` and `--summary all`; `--cache-dir` under the cache
root that run selected and `--global-cache-dir` at the caller's global cache;
and `--prefix` at the prefix that run named, propagated rather than resolved
inside this tree. In the four runtime-loaded cases the provider arrived as
`-- --provider <path>`, and every provider variable was absent from the child
environment — `LUA_TEST_PROVIDER` among them — so what opened the object was
the command line and not an inherited value. The full record is
[`CHANGELOG.md`](CHANGELOG.md) entry 13; it is bounded to those nine cases and
covers neither `cd consumer && zig build run` entered directly nor any of the
rows below.

The `consumer` step runs the nested build when this host can execute the
selected target and installs it when it cannot, so `hostCanExecute` decides
rather than the target query: `-Dtarget=aarch64-linux-gnu` with no `-fqemu`
installs `consumer/zig-out/bin/lua-consumer` instead of running it, while an
enabled `-fqemu`, `-fwasmtime`, `-fwine` or `-fdarling` still runs. An installed
foreign consumer is compile evidence and never a semantic pass.

History behind the counts: an earlier run of the linked route passed 16/16
against the suite as it stood then, and the suite has since grown to 19 — the
exact collector byte count and two tests that pin `isCollecting` from inside a
`__gc` metamethod and inside a finalizer `lua_close` runs. The first three
rows are the runs that cover the suite as it now stands, in both the linked and
the runtime-loaded configuration; the fourth runs the consumer package, not the
suite.

### The source-bound 53-cell matrix and baseline, 2026-10-04/05

One external driver ran this SDK's 53 platform cells at `-j8`, and a second ran
the compile-only baseline. Both receipts carry one source identity, and that
identity is the boundary of every number below.

| Gate | Receipt | Result |
|---|---|---|
| 53-cell platform matrix | `resume-8-evidence/20261004T221720228710Z-45046/lua-53-target-8.json` | **53 cells, `pass 20`, `build_only 30`, `build_fail 3`, run exit 1.** 20 executed this SDK's suite and passed; 30 compiled with no available runner; 3 stopped before a test ran |
| Compile-only baseline | `baselines-and-configs/20261005T014547Z-797a73f2/receipts/baseline-lua-check-2026-10-05T01-45-49Z.json` | exit 0, `failed: false`. `check` compiles and runs nothing, so no test number may be read out of it |
| Native route, 8 cells | `native-final-evidence/20261004T233628757747Z-69351/run.json` | 8 of 8 passed |
| Own-provider loaded route, 8 cells | `loaded-final-evidence/20261004T232823091897Z-23133/run.json` | 8 of 8 passed, against this SDK's own shared object |

`build_only` is compiled-not-run and is **never** counted as a test pass: 30 of
the 53 cells are coverage of the compiler, not evidence about behaviour.

**The three red cells are two different things, and neither is a reported
defect in the library.** Two are `aarch64-netbsd` and `aarch64_be-netbsd`, which
stop on one diagnostic — `error: use of undeclared identifier '__int128_t'`,
recorded in the receipt as `lua-translate.zig:1584:43` — in the NetBSD
translator front end that `CHANGELOG.md` entry 7 already describes for this
SDK. That cause was **not re-derived** for this matrix, so it stands as an open
item. The third is `wasm32-wasi`, and it is this build's own deliberate
refusal, printed before a compiler is invoked: *Lua has no buildable
configuration for this target: `src/loslib.c`'s `tmpnam` configuration has no
arm this toolchain's WASI libc can compile*. That refusal is described under
"The cross-target matrix" below and is the expected answer for this target.

**What this matrix does not cover.** The 53-cell run predates the later
build-graph, header and normalization edits, including `CHANGELOG.md` entry 15's
system-mode correction; its `source_unchanged: true` speaks only to its own run
and those edits are not claimed to be covered by it.

**System mode, and what is still unobserved about it.** `CHANGELOG.md` entry 15
gave system mode's single `lua.pc` query to the `TranslateC` step, so the
`-I${includedir}` reaches `zig translate-c` and the declarations and the library
come from one prefix. A driver gate has since run that route and it **exited 0
with every answer matched**, which is the semantic result and the only part of
the route that has been observed. The diagnostic that would show *which*
`lua.h` the translation read — the one that distinguishes the pkg-config
`includedir` from the host's own Lua — was not captured, so that half is
unproven. That is a gap in the observation, not a reported failure of this SDK,
and entry 15 stays `PENDING-VERIFICATION` until a gate records both.

### What is still pending

| Gate | Command | Status |
|---|---|---|
| Shared delivery, tests and smoke | `zig build smoke test -Dlinkage=dynamic` | PENDING-VERIFICATION |
| Runtime-loaded against the shared delivery | `zig build smoke test -Druntime=true -Dlinkage=dynamic` with an explicit provider | PENDING-VERIFICATION |
| ReleaseSafe | `zig build test -Doptimize=ReleaseSafe` | PENDING-VERIFICATION |
| Static closure installed to `out` | `zig build install --prefix out` | PENDING-VERIFICATION |
| Five compile-only targets, plus the refused `wasm32-wasi` row | `zig build check` | PENDING-VERIFICATION |
| Published platform matrix | `cross-test` | `OBSERVED` on the source epoch the receipt records — 53 cells, 20 executed, 30 `build_only`, 3 refused or failed; see "The source-bound 53-cell matrix and baseline" above. A replay against the current source is still owed |
| Consumer package entered directly | `cd consumer && zig build run` | PENDING-VERIFICATION |
| Nix variants | `nix build .#static`, `nix build .#shared` | PENDING-VERIFICATION |
| devenv outputs | `devenv build outputs.static`, `devenv build outputs.shared` | PENDING-VERIFICATION |
| Provenance script | `tools/check-provenance.sh` | PENDING-VERIFICATION |

### The cross-target matrix

`zig build check` compiles and links the native library, the facade, the tests
and the example for the five compile-only targets without running any of them:
`x86_64-linux-gnu`, `aarch64-linux-gnu`, `aarch64-macos-none`,
`x86_64-windows-gnu` and `riscv64-linux-gnu`. A successful foreign compile is
`build_only`, not a passing test.

The full published platform matrix is run by `cross-test.profile.sh` and
`"$HOME/.local/bin/cross-test"`. Neither has been run here.

One boundary is known from the source and is stated rather than discovered:
**this package has no buildable configuration for `wasm32-wasi`, under any
delivery.** `refusalFor` (`build.zig:1909-1976`) holds the reason —
`src/loslib.c:97-130` gives `os.tmpname` exactly two arms and Zig 0.16.0's
WASI libc supplies neither `mkstemp` nor `L_tmpnam` — and `refuseTarget`
(`build.zig:1985-1991`) prints it and stops, before a compiler is invoked. The
target is named in `refused_check_targets` (`build.zig:601-603`) rather than
dropped, `checkMatrixPartition` (`build.zig:2001-2020`) fails any build of this
package if the refusal ever lapses without the row having been moved back and
proved, and both CI matrices carry a named step that asserts this refusal and
this diagnostic instead of a compile.

That refusal is *not* the shared-delivery one. `deliveredLinkage`
(`build.zig:1871-1894`) does refuse a target whose OS has no dynamic linker,
and WASI has none, so the two refusals overlap on this target — but `addGraph`
calls `refuseTarget` at `build.zig:821`, immediately after the platform is
resolved, and `deliveredLinkage` is not first reached until `build.zig:1682`.
The "no dynamic linker" wording is therefore never printed for `wasm32-wasi`,
and a gate that waited for it would wait for text this build cannot produce.
The same ordering is why the static and default builds do not cover the row
either: there is no delivery under which this target is attempted.

This is a statement about this pinned `src/loslib.c` against this toolchain's
WASI libc with nothing substituted for it, not a claim that WASI cannot host
Lua. Everything else is reported from the driver's own runs rather than
predicted here.

## Consumption

### From Zig, typed

`@import("lua")` is the documented facade published by `zig/root.zig`. `State`
owns one `lua_State` and covers its whole life — `init`/`initWithLibraries`,
`deinit`, library opening, the stack, values and types, tables and globals,
`load`/`pcall`, the error surface, the garbage collector and threads.
One behavioural detail is worth stating here rather than leaving to be
discovered: `runChunk` compiles a chunk and calls it with **no results
retained** — it is `load` followed by `pcall(0, 0, 0)` — and on failure it
leaves the error object on the stack. To keep what a chunk returns, use `load`
and `pcall(0, n, 0)` (or `multret`) and read the results with `toInteger`,
`toNumber`, `toBytes` or `typeOf`. That is what the example program and
`tests.zig` do.
`ThreadRef` is a non-owning coroutine view, deliberately without a `deinit`.
Constants (`version_num`, `signature`, `multret`), the `Type`, `Status`,
`Library`, `CompareOp` and `ArithOp` enums, and `version_ident()` — which reads
`lua_ident` from the provider's own address — are published alongside.

The full surface, its ownership rules and its ABI boundary are in
[`README.zig.md`](README.zig.md).

### From Zig, the raw native route

```zig
const c = @import("lua").c; // the translated headers, verbatim
```

The raw route is the whole header-declared Lua C API — `lua_*` from `lua.h`,
`luaL_*` from `lauxlib.h` and `lualib.h`, and the ten `luaopen_*` openers —
with upstream's own types, constants and callbacks. It carries four things
beyond the declarations, and the typed facade is a convenience over them, not a
replacement:

* **Every declared entry point**, including the ones the facade does not wrap:
  `lua_dump`, `lua_getinfo`, `lua_pushvfstring` with its `va_list`, the
  `luaL_Buffer` builders, `luaL_loadfilex` and every `luaL_check*` helper.
* **The macro spellings.** `translate-c` translates the headers'
  function-like macros into wrappers over the entry points they expand to, so
  `c.lua_pop(L, n)` is `lua_settop(L, -(n)-1)` (`src/lua.h:396`),
  `c.lua_newtable(L)` is `lua_createtable(L, 0, 0)` (`:398`),
  `c.lua_tostring(L, i)` is `lua_tolstring(L, i, NULL)` (`:418`),
  `c.lua_call(L, n, r)` is `lua_callk(L, n, r, 0, NULL)` (`:295`),
  `c.lua_pcall(L, n, r, f)` is `lua_pcallk(L, n, r, f, 0, NULL)` (`:299`),
  `c.lua_pushcfunction(L, f)` is `lua_pushcclosure(L, f, 0)` (`:402`),
  `c.lua_pushglobaltable(L)` is the raw `lua_rawgeti` on the registry
  (`:415-416`), and `c.luaL_openlibs(L)` is `luaL_openselectedlibs(L, ~0, 0)`
  (`src/lualib.h:62`). `lua_tonumber`, `lua_tointeger`, `lua_getextraspace`,
  `lua_resetthread`, `lua_register`, `lua_pushliteral`, `lua_isnil`,
  `luaL_checkstring`, `luaL_typename`, `luaL_newlib` and `luaL_newlibtable` are
  carried the same way, with upstream's own operands; `lua_absindex`
  (`src/lua.h:177`) and `lua_xmove` (`src/lua.h:185`) are ordinary functions in
  5.5.1, not macros. A macro whose body cannot be lowered arrives as a `pub
  const` whose value is `@compileError` — a name that exists and cannot be
  called: `c.luaL_addchar`, `c.luaL_addsize` and `c.luaL_buffsub`
  (`src/lauxlib.h:201`, `205`, `207`), plus `c.lua_str2number` and
  `c.lua_getlocaledecpoint` from `luaconf.h`. A caller that wants one of those
  writes the expansion.
* **The three real C variadics** — `lua_pushfstring` (`src/lua.h:252`),
  `luaL_error` (`src/lauxlib.h:76`) and `lua_gc` (`src/lua.h:360`) — which
  arrive as Zig variadics. A linked build calls them with promoted arguments; a
  runtime-loaded build calls them with the trailing arguments as one tuple.
  Both spellings are compiled and run by `smoke.zig` and `tests.zig`, with the
  condition on `runtime_loaded` resolved at comptime so a build only ever
  analyzes the route it has.
* **Live exported data.** `lua_ident` (`src/lua.h:157`, defined at
  `src/lapi.c:35`) is bound to an `@extern` of its declared pointer type, so the
  value is the provider's address rather than a copy of its bytes;
  `version_ident()` reads those bytes, and in a loaded build it reads them out
  of the object that was actually opened. The runtime-loaded run printed that
  provider's own `$LuaVersion: Lua 5.5.1 …` string.

A macro is still not a symbol, and that is exactly what the load boundary turns
on: the delivered shared object exports no `lua_pop`, `lua_newtable` or
`lua_tostring`, only what those spellings expand to. So a loaded route resolves
a macro's *target*, and the facade's own calls name the declarations directly
(`discardError` calls `lua_settop`, `call` calls `lua_callk`, `register` calls
`lua_pushcclosure`), which is why there is no macro name in the table to resolve.

### From C

The installed tree carries the five public headers and the library, so a C
consumer needs nothing but an include path and `-llua`:

```c
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

lua_State *L = luaL_newstate();
luaL_openlibs(L);
lua_close(L);
```

```sh
cc -I"$prefix/include" prog.c -L"$prefix/lib" -llua -lm -o prog
```

`pkg-config --cflags --libs lua` reports the same thing from the installed
`lua.pc`, which for a shared install also carries the `LUA_BUILD_AS_DLL` flag a
C consumer needs to get `dllimport` on Windows.

### With Nix

`package.nix` is the single source-only derivation; `flake.nix` and
`devenv.nix` both call it, so they cannot describe different packages.

```sh
nix build .#static     # liblua.a
nix build .#shared     # liblua.so
nix build .#default    # the SDK's own policy: static, as upstream builds only an archive
devenv shell           # canonical development environment, tools only
devenv build outputs.static
devenv build outputs.shared
```

Entering the devenv shell does not build the package. Nothing in the packaging
hard-codes a host path, an account name or a store path, and no derivation
downloads anything.

The devenv input is one pinned revision and nothing else. There is no `flake:`
key on it: `flake: false` makes devenv read the input as a plain source tree, a
plain source tree has no `lib`, and every devenv subcommand then dies at
bootstrap with `error: attribute 'lib' missing`. `devenv.lock` is written by
the driver, not by this file.

The canonical tasks run with `devenv tasks run <name>`:

```sh
devenv tasks run sdk:build           # compile and install, into an external prefix
devenv tasks run sdk:build:shared    # the same, as a shared object
devenv tasks run sdk:test            # and sdk:test:release-safe, sdk:smoke, sdk:check
devenv tasks run sdk:consumer        # the separate consumer package in consumer/
devenv tasks run sdk:provenance      # tools/check-provenance.sh
devenv tasks run sdk:package:static  # devenv build outputs.static
```

Each of those bodies enters this checkout before it runs anything. devenv
materialises a task as a generated shell program that inherits the caller's
working directory, so a body that assumed it was already here would be working
in whatever directory the caller started from — under
`devenv --from path:<sdk>` from a scratch project, a directory with no
`build.zig`, no `consumer/` and no `UPSTREAM.sha256`. The path each body uses
is read out of `devenv.nix`'s own location at evaluation time, so no host path
is written in that file and this SDK is not copied into the store to be read
there instead.

What a task writes lands outside the tree too. `zig build` installs into
`zig-out/` and keeps its local cache in `.zig-cache/`, both relative to the
working directory, so the two installing tasks pass `--prefix` and every task
passes `--cache-dir`, beneath `ZIG_LOCAL_CACHE_DIR`: the caller's if one was
exported, otherwise `$XDG_CACHE_HOME`, otherwise `$TMPDIR`. A task with none of
the three set stops and says why rather than writing into a checkout whose
file set is what the driver digests. `sdk:package:static` and
`sdk:package:shared` are the deliberate exception: they run a nested
`devenv build`, which reads the project the caller entered and delivers a store
path.

### Runtime loading

`-Druntime=true` swaps the linked calls for calls through one process-lifetime
table, selected explicitly:

```zig
const lua = @import("lua");

fn start() !void {
    try lua.load(.{ .path = "/usr/local/lib/liblua.so.55" });  // an absolute path
    try lua.load(.{ .system = "liblua.so.55" });                // the soname
}
```

There is no path-to-system fallback, no automatic retry and no unload. Calling
any native entry point before a successful load panics in every optimization
mode. Loading a table is a pointer-resolution step, not an ABI proof: the
scalar, layout, configuration and allocator requirements a provider must meet
are listed in [`README.zig.md`](README.zig.md).

One such load has been observed: `-Druntime=true` against a real
`liblua.so.55.5.1` that this graph built from these sources and installed,
named explicitly as above. The program reported the provider's own identity
(`$LuaVersion: Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio …`) rather
than a constant compiled into it. That run carried the **whole test binary
through the dispatch, not only the example**: 9/9 build steps and 19/19 tests,
with every expected answer matched — the typed stack, the retained results, the
error surface, the collector and its exact byte count, `isCollecting` from
inside a finalizer, and the raw `lua_pushfstring` tuple call. So the loaded
route is exercised by the same 19 assertions as the linked one, and the shared
*delivery* is not yet: a `-Dlinkage=dynamic` package has only been installed
(26/26 steps), not run.

## Commands

```sh
zig build            # library, lua and luac
zig build -Dlinkage=dynamic
zig build test
zig build test -Doptimize=ReleaseSafe
zig build smoke
zig build check
zig build install --prefix out
zig build consumer
cd consumer && zig build run
tools/check-provenance.sh
```

`zig build consumer -Druntime=true` names no provider, so the consumer program
asks for one. A caller names one on the command line:

```sh
zig build consumer -Druntime=true -- --provider /path/to/liblua.so.55
```

Those words reach the program through two hops. `runConsumer` passes the outer
`b.args` behind `--`, so the nested graph in `consumer/` collects them, and
`consumer/build.zig` passes its own `b.args` to the run step it builds from the
executable. `LUA_TEST_PROVIDER` is the other route and needs no argument. With
nothing after `--`, both hops add nothing, so the bare `zig build consumer`
above is unchanged by either. This is read out of the two build files, and no
gate has run against it.

## Licence

Lua is **MIT**, Copyright (C) 1994-2026 Lua.org, PUC-Rio. The grant is in
`src/lua.h:523-544` and in `doc/readme.html`; every file this SDK ships from
upstream keeps it, and the installed tree carries it too.

This fork's own files — build, typed surface, tests, example, consumer,
runtime table, packaging, integrity script and documentation — are **MIT** under
the owner's per-project authorization, recorded with the full text in
[`FORK-LICENSE.md`](FORK-LICENSE.md). Lua.org is not claimed as the author of
any of them, and the fork's licence adds no condition to Lua's.

Upstream's obligation survives both: if you ship Lua, reproduce the Lua.org
copyright notice and the permission text. [`NOTICE.md`](NOTICE.md) says where
each one travels and carries the per-file inventory — which in this project is
uniform, because Lua's grant has no per-file exceptions.

## Upstream README, verbatim

Upstream's own README is reproduced here exactly, at the end, because that is
where a reader should find it. The same 151 bytes are carried as `README`, under
the name the tarball gave that file, and as
[`README.upstream.md`](README.upstream.md); both have sha256
`7805901a81d7b26021652c3b81cb2793bcea88f940b13ea66f901fb8be544fba`, which is
the record in [`UPSTREAM.sha256`](UPSTREAM.sha256). Nothing above this line has
rewritten a word of it.

```text

This is Lua 5.5.1, released on 24 Jul 2026.

For installation instructions, license details, and
further information about Lua, see doc/readme.html.

```