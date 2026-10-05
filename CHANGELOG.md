# Changelog

Numbered, newest last. Each entry says what changed and what it did **not**
prove.

Entry 6 records the gates that have since run. Everything an earlier entry
marked unverified is either still unverified or is superseded by entry 6; the
most recent statement about any gate is the last entry that mentions it.
Statements read out of files are marked `SOURCE-CONFIRMED` and name the file
and line they came from; results the driver observed name the configuration and
what it printed.

## 1. 2026-10-04 — import of the official Lua 5.5.1 release

`SOURCE-CONFIRMED`. The upstream release `lua-5.5.1.tar.gz` (2026-07-24,
398643 bytes, sha256 `1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce`)
was imported whole: `src/` (63 files), `doc/` (10), `Makefile`, `src/Makefile`
and `README`. 75 files, 1416954 bytes, every one recorded by digest in
`UPSTREAM.sha256`.

No upstream file has been edited. `tools/check-provenance.sh` fails if a
recorded digest stops matching, if the file set under `src/` or `doc/` gains or
loses a file, if `README` and `README.upstream.md` stop being byte-identical, or
if the Lua.org notice disappears from `src/lua.h`.

Recorded facts, each read out of the tree rather than assumed:

* The tarball contains **no test suite**. `src/Makefile:69-70` defines `test:`
  as `./$(LUA_T) -v`.
* Nothing is generated at build time; `src/ljumptab.h` is a checked-in file
  carrying its own refresh command (`src/ljumptab.h:21-25`).
* The complete library closure is `src/Makefile:36-37`: 20 `CORE_O` units, 12
  `LIB_O` units, plus `lua.c` and `luac.c`.

Not verified: anything requiring a compiler. No build has been attempted.

## 2. 2026-10-04 — provenance, licence and integrity records

Added `README.md`, `README.zig.md`, `UPSTREAM.md`, `UPSTREAM.sha256`,
`NOTICE.md`, `FORK-LICENSE.md`, `FORK-NOTES.md`, this file and
`tools/check-provenance.sh`.

* `README.upstream.md` is a byte-identical copy of the tarball's `README`
  (151 bytes, sha256 `7805901a81d7b26021652c3b81cb2793bcea88f940b13ea66f901fb8be544fba`).
  Upstream's own installation and licence notes remain in `doc/readme.html`,
  unaltered.
* Lua's terms are MIT, Copyright (C) 1994-2026 Lua.org, PUC-Rio, carried by
  `src/lua.h:523-544`. The per-file inventory in `NOTICE.md` records that 60 of
  the 63 files in `src/` carry `** See Copyright Notice in lua.h`, that the
  three that do not are `lua.h` (which is the notice), `lua.hpp` (no comment
  block) and `Makefile`, and that lua.org's own download index states that all
  files of the tarball are distributed under that licence.
* This fork's own files are MIT under the owner's per-project authorization,
  with the full grant, the authority and the limits recorded in
  `FORK-LICENSE.md`. No individual copyright holder is named and no upstream
  authorship of fork code is claimed.
* The release digest is recorded identically in `UPSTREAM.md` and
  `UPSTREAM.sha256`, and the integrity script fails if the two disagree.

Not verified: no gate has read these files back. The integrity script itself has
never been executed; it is delivered as source.

## 3. 2026-10-04 — standalone Nix and devenv packaging

Added `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml` and `.envrc`.

* `package.nix` is one uncurried derivation taking injected `lib`, `stdenv`,
  `zig` and an optional `linkage`. `flake.nix` and `devenv.nix` both call it
  with `pkgs.callPackage`, so the two entry points cannot describe different
  packages.
* `flake.nix` exposes `packages.<system>.static`, `.shared` and `.default`;
  `.default` preserves the SDK's policy, which is static because upstream's own
  `Makefile` builds only an archive (`Makefile:44`).
* `devenv.nix` carries tools only and names the same derivation lazily as
  `outputs.static`, `outputs.shared` and `outputs.default`, so entering the
  shell does not build the package. `devenv build outputs.static` and
  `devenv build outputs.shared` are the real packaging route.
* The install phase runs `zig build install --prefix "$out"` with one optimize
  selection, `-Dcpu=baseline`, the requested `-Dlinkage`, `-j` from
  `NIX_BUILD_CORES` and both Zig caches under the Nix-provided `TMPDIR`. It
  copies and generates nothing by hand, so the build graph is the only writer of
  every installed path.
* The derivation refuses a cross build by comparing `stdenv.buildPlatform.system`
  with `stdenv.hostPlatform.system`. Both are pure values; `builtins.currentSystem`
  is not used, and a remote builder is unaffected.
* No host path, account name, store path, sibling checkout or build-time download
  appears in the packaging. The nixpkgs input is pinned by revision in both
  entry points; `flake.lock` and `devenv.lock` are the driver's to write.

Not verified: no `nix build`, no `devenv` invocation and no evaluation of these
files has happened here.

## 4. 2026-10-04 — native delivery, and the documentation corrections it forced

The native build graph landed (`build.zig`, `build.zig.zon`,
`zig/translate.h`, `consumer/build.zig`, `consumer/build.zig.zon`,
`cross-test.profile.sh`, `.gitignore`, `.github/workflows/verify.yml`). This
entry records what the canonical documents now say about it, and the three
corrections that landed with it.

* `-Dlinkage=static|dynamic` (default static), `-Druntime=bool` (default
  false), `-Dsystem=bool` (default false), and steps `zig build` (which is the
  `install` step), `test`, `smoke`, `consumer` and `check`. `zig build install`
  is that same step: Zig 0.16.0's default top-level step is named `install`
  (`lib/std/Build.zig:298-302` in the pinned compiler), and it carries the
  library, both programs, the five headers, `lua.pc`, both man pages and the
  nine licence records. `package.nix` depends on that, and every install call
  in `build.zig` is bound explicitly: a dropped install return value is a step
  outside the graph, which installs silently incomplete and still exits zero.
* Installed closure: `lib/liblua.a` or `lib/liblua.so.55.5.1` with the soname
  `liblua.so.55` and the `liblua.so` link name; five headers flat in
  `include/`; `lib/pkgconfig/lua.pc`, the only generated file; `bin/lua` and
  `bin/luac`; `share/man/man1/{lua,luac}.1`; and `share/licenses/lua/`
  holding `readme.html`, `lua.h`, `README`, `NOTICE.md`, `FORK-LICENSE.md`,
  `UPSTREAM.md`, `UPSTREAM.sha256`, `FORK-NOTES.md` and `CHANGELOG.md`.

**Correction 1 — the soname.** The load example in `README.md` and
`README.zig.md` had `.system = "liblua.so.5.5"`. There is no such soname: the
only ABI number upstream states is 55 (`src/Makefile:132-135`, `lua55.dll`), so
the file is `liblua.so.55.5.1` and the soname is `liblua.so.55`. Both examples
now use `liblua.so.55`.

**Correction 2 — export visibility.** The shared object exports Lua's public
namespaces on ELF, where a generated version script exports `lua_*`, `luaL_*`
and `luaopen_*` and marks everything else `local`. It is a namespace, not a
hand-maintained list of the 156 declarations, so a header that gained or lost a
function cannot leave the export list behind, and the published data object
rides in with the namespaces. On Windows the `LUA_BUILD_AS_DLL` split gives
`LUA_API` its `__declspec(dllexport)` and a generated module definition file
carries the one entry the macro does not reach — `lua_ident DATA`, because
`src/lua.h:157` declares that object without `LUA_API`. On Darwin and COFF the
shared object also exports Lua's internal symbols, because `LUA_API` is plain
`extern` outside Windows (`src/luaconf.h:315`) and no Mach-O equivalent is
available. Recorded in README.md's build deviations, README.zig.md's ABI
section and FORK-NOTES.md §7a.

**Correction 3 — no shared delivery for `wasm32-wasi`.** `-Dlinkage=dynamic` is
refused for a target with no dynamic linker, with a message naming the target,
rather than silently substituted with an archive. The static and default
builds cover that row. Recorded in README.md's cross-target section and
FORK-NOTES.md §7.

Also recorded in FORK-NOTES.md: the deliberate omission of `-D_REENTRANT` on
Solaris (upstream's own `src/Makefile:139-141` passes it; no observed failure
stands behind either choice), the deliberate use of `LUA_USE_POSIX` +
`LUA_USE_DLOPEN` rather than `LUA_USE_MACOSX` on Darwin so that readline stays
an optional runtime `dlopen` instead of a link-time `-lreadline`, and the
configure-time refusal when `build.zig.zon`'s `.version` disagrees with
`src/lua.h:20-22`.

Not verified when this landed: no gate had run. Entry 6 records what has since.

## 5. 2026-10-04 — typed surface, runtime table and behavioural tests

`zig/root.zig`, `tests.zig`, `smoke.zig`, `consumer/src/main.zig`,
`runtime/library.zig` and `runtime/graph.zig` landed. `README.zig.md` now
documents the published surface by name instead of by category, and
`README.md`'s consumption section names it.

* **Route.** `@import("lua")` from `dep.module("lua")`; the translated headers
  are re-exported as `pub const c = @import("c")` on that module, not published
  separately.
* **Surface.** `runtime_loaded`, `LoadSource` (`.path`/`.system`), `LoadError`,
  `load`, `loadedSource`; the constant set including `version_ident()`; the
  `Type`, `Status`, `Library`, `CompareOp` and `ArithOp` enums; `State` in
  full, from `init`/`deinit` through the collector to threads; and `ThreadRef`
  as a non-owning coroutine view.
* **Ownership, as documented.** A failed `pcall` replaces the chunk slot with
  exactly one value and moves nothing else; `errorMessage` borrows and
  `takeError` copies then pops, leaving the value in place when it cannot take
  it; the `longjmp`-based entry points are legal only inside a C function Lua
  invoked under `pcall`, never across a Zig `defer`; `luaL_newstate` reaches
  libc `realloc`/`free` with no Zig allocator in the path and no leak oracle;
  and `ThreadRef` has no `deinit` because `lua_newthread` does not close and a
  second close would run pending `__close` metamethods twice.
* **Family validation.** `runtime/library.zig` accepts a Lua 5.5 provider
  (`LUA_VERSION_NUM` 505) and **refuses LuaJIT 2.1 (501)**, so a 5.1 provider
  cannot pass a name check into this build. Recorded in README.zig.md's ABI
  section and FORK-NOTES.md §6.
* **Macro spellings on the raw route.** `lua_pop`, `lua_newtable`,
  `lua_tostring`, `lua_call`, `lua_pcall`, `lua_pushcfunction`,
  `lua_pushglobaltable`, `lua_register`, `lua_tonumber`, `lua_tointeger`,
  `lua_getextraspace`, `lua_resetthread`, `lua_pushliteral`, `lua_isnil`,
  `luaL_checkstring`, `luaL_typename`, `luaL_dostring`, `luaL_newlib`,
  `luaL_newlibtable` and `luaL_openlibs` are macros in the C headers, and the
  translation carries them as wrappers over the entry points they expand to —
  with upstream's own operands and the upstream line for each. `lua_absindex`
  (`src/lua.h:177`) and `lua_xmove` (`src/lua.h:185`) are plain functions in
  5.5.1 and are declared as such. `zig/root.zig` spells out the ones the facade
  wraps (`discardError` → `lua_settop`, `call` → `lua_callk`, `register` →
  `lua_pushcclosure`, `openLibraries` → `luaL_openselectedlibs`), which is why
  no macro name appears in the runtime table. See entry 6 for the correction to
  the earlier claim that these had no `c` counterpart at all.
* **Tests.** `tests.zig` covers 5.5 arithmetic and integer wraparound, strings
  as byte sequences with embedded NULs, protected-call stack and error
  behaviour including non-string error objects and message handlers, library
  opening, a Zig callback with `luaL_error` contained by `pcall`, the
  collector, stack positions, closing as a transition, threads, the raw
  variadic route, numeric boundaries and value identity — independent known
  answers and behavioural boundaries only.

Not verified when this landed: no gate had run. Entry 6 records what has since.

## 6. 2026-10-04 — export patterns, the real translation, and the first observed gates

Three things changed together: how the shared object decides what to export,
what this repository claimed about the translation, and what the driver
actually ran.

**The manual export catalogue is gone.** The ELF version script is now the
three public namespaces — `lua_*`, `luaL_*`, `luaopen_*` — with everything else
`local`, so the published data symbol comes along with them instead of being
enumerated. On Windows a generated module definition file carries the one entry
`LUA_BUILD_AS_DLL` cannot reach, `lua_ident DATA`. There is no second list of
declarations anywhere in the build graph, and no header declaration can be
exported by omission.

**Corrections to what the documents said about the translation.** Two claims
were false and are now replaced by what the translation actually produces:

* "Nothing is generated at build time" was true of the native C and false of
  the build. `lib/pkgconfig/lua.pc`, the ELF version script and — only under
  `-Druntime=true` — the dispatch are generated; none is a second source of
  truth for the C, and the bullet now says which three.
* The macros were described as absent from `c`. They are present: the
  translation turns the headers' function-like macros into wrappers over the
  entry points they expand to, and README.md, README.zig.md and FORK-NOTES.md
  now list them with the upstream line for each. What remains true is the part
  that matters at the boundary: a macro is not a symbol, so the shared object
  exports no `lua_pop`, and the runtime table resolves what the macro expands
  to.

Also recorded: the three real C variadics — `lua_pushfstring` (`src/lua.h:252`),
`luaL_error` (`src/lauxlib.h:76`) and `lua_gc` (`src/lua.h:360`) — reach Zig as
variadics and take their trailing arguments as one tuple through the loaded
dispatch; `lua_ident` (`src/lua.h:157`) is bound to an `@extern` of its
declared pointer type, so the value is the provider's address and not a copy of
its bytes; and `runChunk` retains no results, so `load` + `pcall(0, n, 0)` is
how a caller keeps what a chunk returned. Upstream's own README is now
reproduced at the end of README.md, byte for byte.

**The collector's byte count is now exact, and the accessors say which is
which.** `State` publishes `garbageKilobytes()` and `garbageBytes()`;
`garbageBytesTotal` is gone with no alias. The first is `LUA_GCCOUNT`
(`src/lua.h:334`) read from `lua_gc`'s return value
(`src/lapi.c:1193-1197`); the second is the whole number in bytes, composed
from `LUA_GCCOUNT` and the `LUA_GCCOUNTB` remainder (`src/lua.h:335`,
`src/lapi.c:1198-1201`) the way `src/lbaselib.c:210-215` composes them for
`collectgarbage("count")`. Neither collects, and both answer null when
upstream refuses with `-1` (`src/lapi.c:1175-1176`), which a `__gc` metamethod
can reach (`src/lgc.c:978-980`) — a collector the caller stopped is not that
case. `tests.zig` proves the total rather than assuming it: a state opened
through `c.lua_newstate` with a counting `lua_Alloc`, the collector stopped,
and a payload length chosen so the total is not a whole number of kibibytes,
then `garbageKilobytes()` against the allocator's live total shifted down by
ten, `garbageBytes()` against it exactly, and both against Lua's own
`collectgarbage("count") * 1024`.

`isCollecting` follows the same rule, and had to be repaired to do it: it now
answers upstream's own boolean — `true` while the collector is running and
`false` once a caller has stopped it through `stopGarbageCollector`
(`src/lua.h:337`, `src/lapi.c:1221-1222`, `src/lgc.h:216`) — and null in the two
windows where `lua_gc` refuses every selector: a `__gc` metamethod, which
upstream runs from inside a cycle (`src/lgc.c:968-987`), and the pending
finalizers `lua_close` runs through `luaC_freeallobjects`
(`src/lgc.c:1529-1536`). In both of those a collection is in fact running, so
null means upstream declined to answer rather than that nothing is collecting;
the earlier shape compared the selector against zero, which answered the same
`true` for a collector a caller had stopped. `tests.zig` pins all four answers,
and proves each finalizer ran through a record in the test's own frame rather
than through a module-level optional, where an untouched null could not be told
from a refusal.

**What the driver observed**, each against artifacts this graph builds:

| Configuration | Result |
|---|---|
| Linked, static | 9/9 steps, **19/19 tests passed**; the smoke matched every expected answer |
| Shared delivery | 26/26 steps; `liblua.so.55.5.1`, soname `liblua.so.55`, full installed closure |
| Runtime-loaded, static delivery | 9/9 steps, **19/19 tests passed** against an installed `liblua.so.55.5.1` named explicitly — the whole test binary and the smoke through the dispatch — and the provider's own `$LuaVersion: Lua 5.5.1 …` banner printed |

The 19/19 rows are the runs that cover the suite as it now stands, in both
configurations: `local://foundation-resumed-lua-gc-finalizer-unreachable.json`
for the linked route and `local://foundation-resumed-lua-gc-loaded-finalizer-unreachable.json`
for the runtime-loaded one, each exit 0 and each carrying `Build Summary: 9/9
steps succeeded; 19/19 tests passed`. History behind the count: an earlier
linked run passed 16/16 against the suite as it stood then, before the exact
byte count and the two `isCollecting` refusal tests were added; that earlier
figure is kept as the record of that run and is not a claim about the suite
now. Fixing a reachability bug in the finalizer test — a collection only
finalizes unreachable objects, while `lua_close` runs pending finalizers
whatever their reachability — was what those two receipts exercised, which is
why the count moved and the assertions did not.

The shared object's export surface was read from the delivered ELF object
itself: `nm -D` reports 157 defined dynamic symbols — 99 `lua_` (98 `LUA_API`
plus `lua_ident`), 48 `luaL_` and 10 `luaopen_` — and no internal namespace.

Not verified, and unchanged by any of the above: the shared delivery has not
been run through `test` and `smoke`, the runtime-loaded route has not been run
against the shared delivery, `-Doptimize=ReleaseSafe` has not been run, neither
`zig build check` nor the published platform matrix has been run, and the Nix,
devenv, consumer and provenance gates are unrun. A passing configuration here
is not a statement about the other three, about Windows, or about the 53-target
matrix.

## 7. 2026-10-04 — the BSD translation front end, and macCatalyst's `os.execute`

Two corrections in the same wave, both `PENDING-VERIFICATION`: a cross BSD
translation failure with a cause, and a macCatalyst boundary. No gate has run
against either.

**The BSD translation failures have a cause and a causal fix.** Three header
behaviours in Zig 0.16.0's bundled C libraries defeat Aro, and
`src/lauxlib.h:13`'s `<stdio.h>` is the door all three come through:

* **NetBSD — `_Pragma`.** `generic-netbsd/sys/cdefs.h:431-432` routes
  `__END_DECLS` through `__END_PUBLIC_DECLS`, which `:411-413` spells as
  `__END_EXTERN_C` framed by `_Pragma("GCC visibility pop")`, and
  `generic-netbsd/stdio.h:149` opens a block with `__BEGIN_DECLS`. Aro
  destringizes each `_Pragma` into a `#pragma` line and hands it to its parser
  as C. One header, one cause, the whole family.
* **OpenBSD 32-bit — `size_t`.** Every OpenBSD `machine/_types.h` in this
  toolchain spells `__size_t` as `unsigned long`
  (`x86-openbsd-none/i386/_types.h:123`, `arm-openbsd-eabi/arm/_types.h:123`),
  and `generic-openbsd/stdio.h:49-52` declares `typedef __size_t size_t` under
  `_SIZE_T_DEFINED_` — a guard Aro's own `<stddef.h>`
  (`lib/compiler/aro/include/stddef.h:8`, which declares `size_t` from
  `__SIZE_TYPE__` and sets no such guard) never sets, so the declaration is
  seen twice. On the 64-bit targets both spellings name the same type and
  C's rule on redeclaring a typedef to the type it already has makes the second
  one harmless; on the 32-bit ones the compiler's own `size_t` is not
  `unsigned long` and it is a conflict instead.
* **OpenBSD on MIPS64 — the endian predefines.** `generic-openbsd/stdio.h:46`
  → `generic-openbsd/sys/types.h:45` → `generic-openbsd/sys/endian.h` →
  `generic-openbsd/sys/_endian.h:36-40` → `generic-openbsd/mips64/endian.h`,
  which derives `_BYTE_ORDER` from `__MIPSEL__` or `__MIPSEB__` (`:32-37`) and
  stops the translation with an `#error` at `:39-41` when neither is defined.
  The compiler that compiles the 32 core units predefines one of them for that
  target; Aro does not.

The fix is the front end ERFA already uses, and nothing else. `aggregateRoute`
now hands NetBSD and OpenBSD targets to `preprocessedAggregate`, which runs the
target's own C preprocessor — `b.graph.zig_exe cc -E -dD`, so the same pinned
compiler that compiles the C — over `zig/translate.h` and gives Aro the result
to parse. Both routes read the same header on the same include path with the
same macros and the same C dialect: `c_flags` is passed to the preprocessor
rather than restated, the `-I src` and `-D` list are the ones `add_c_library`
gives the 32 core units, and `-dD` keeps every macro definition so the
translated constant set is unchanged. `-MD`/`-MF` makes the discovered headers
this step's own inputs.

What did not change: the published aggregate (`<lua.h>`, `<lauxlib.h>`,
`<lualib.h>`), the whole public API and constant set, `c_flags`, the platform
macros on every target, the 32-unit C closure, the headers installed, the
program names, the delivery options, and the route every non-NetBSD,
non-OpenBSD target takes. No predefine was invented: the endian macros are
emitted by the compiler that already compiles the core for the same target, and
a `-D` written here would be the package claiming to be the compiler. The
`check` matrix is the same five rows and `wasm32-wasi` is still refused.

Two boundaries this entry deliberately leaves open. The LP64 non-MIPS OpenBSD
cells have no diagnosed cause of their own and take the same front end for
uniformity, not on the strength of a diagnosis. And `generic-freebsd` has the
same header shape under a different guard (`_SIZE_T_DECLARED`,
`generic-freebsd/stdio.h:46-49`): no FreeBSD cell was reported failing, so no
FreeBSD row was changed, and that is the first thing to revisit if one is.

**macCatalyst is given upstream's own `LUA_USE_IOS`, and the boundary it draws
is recorded rather than papered over.** `src/loslib.c:133-140` already has the
arm this target needs: with `LUA_USE_IOS`, `l_system` is
`((cmd) == NULL ? 0 : -1)` instead of `system(cmd)`, under upstream's own
comment — "Despite claiming to be ISO C, iOS does not implement 'system'". That
is an existing C arm, so no C is written here, and it is what upstream's own
`ios` recipe passes (`src/Makefile:120-121`). `src/luaconf.h:86-89` expands
`LUA_USE_IOS` to exactly the `LUA_USE_POSIX` and `LUA_USE_DLOPEN` the Darwin row
already used and to nothing else, so **no readline dependency is added**;
`LUA_USE_MACOSX` was rejected for the reason §7c records — it turns into
`LUA_USE_READLINE` and a link-time `-lreadline`.

The remedy is upstream's and it is not `posix_spawn`. With that arm,
`os.execute("cmd")` on macCatalyst answers `nil, "exit", -1` and `os.execute()`
answers `false`, which is upstream's own statement that there is no shell.
Substituting `posix_spawn` would mean writing the C that runs the child, which
is a substitute for a platform decision rather than a configuration of it.
`os.execute` is therefore recorded as the one standard-library function this
build cannot provide on macCatalyst, unavailable for the reason upstream says
it is. `LUA_USE_IOS` occurs in exactly three places in the imported source
(`src/luaconf.h:86`, `src/Makefile:121`, `src/loslib.c:134`), so that is the
whole of what the macro changes on a Catalyst target.

Not verified: **no gate has observed any part of this entry.** Nothing was
built, compiled, formatted or run, so every cell named above is a correction
recorded at `PENDING-VERIFICATION` and not a result. The three BSD causes are
`SOURCE-CONFIRMED` — every header line is read out of the pinned compiler's
own `lib/libc/include` — but the failures themselves are the driver's report,
not a run this entry performed, and no claim is made that the new route fixes
them until a `cross-test` run says so. `zig build check`, the six-target
baseline and the five buildable rows are unchanged by this entry and are just
as unobserved here as they were in entry 6.

## 8. 2026-10-04 — `Platform.kind` did not compile, and why

Entry 7's `Platform.kind` compared `platform.macros[0][0]` with `==`. That is
not a Zig expression: `platform.macros[0][0]` is a `[]const u8`, and Zig's `==`
covers pointers and scalars, not slices. The build script therefore failed to
compile on **every** configuration, including the host, from the moment entry 7
landed — reported by the driver's Nixbuild run, not observed here. Both
comparisons are now `std.mem.eql(u8, ...)` (`lib/std/mem.zig:732`), and the
doc comment says why the spelling is what it is.

Nothing else in entry 7 changed: the macCatalyst row, the BSD front end, the
aggregate, the macros, `c_flags` and the five `check` rows are exactly as
entry 7 describes them. The label `kind` prints is unchanged, including the new
`upstream's LUA_USE_IOS expansion` for macCatalyst.

The lesson worth keeping is narrower than "write more Zig": the failure was in
a line that named a *label*, not in any of the platform logic, and it was
introduced by a change whose purpose was a label. A label is still code.

**Bound to:** `Platform.kind` in this file and Zig 0.16.0, where `[]const u8`
has no `==`. Under a language or library that adds slice equality this becomes
cosmetic, not a change of meaning.

Not verified: **still no gate has observed entry 7 or entry 8.** The correction
is `SOURCE-CONFIRMED` against `lib/std/mem.zig:732` and nothing was compiled;
the driver's next focused compile of the build script is what moves it.

## 9. 2026-10-04 — the canonical devenv: a deleted key, valid task names,
self-locating bodies, and output that stays out of the tree

`PENDING-VERIFICATION`. Four corrections across two files: `devenv.yaml` loses
one key, and `devenv.nix` renames five task names and rewrites every task body.
No build graph, no native source and no API changed.

**`devenv.yaml` lost `flake: false`; the pin did not change.** The driver's run
`nix-acceptance-20261004T175328Z` recorded all seven lua devenv gates failing
with one error, exit 1 each: `Failed to get attribute 'config.cachix.enable'`
at `<project>/.devenv/bootstrap/bootstrapLib.nix:430:9`, then
`lib = nixpkgs.lib` at `:54:13`, ending in `error: attribute 'lib' missing`.
`flake: false` makes devenv read the nixpkgs input as a plain source tree, and a
plain source tree has no `lib`. The key is deleted; the revision pin
`c2f38fe7f9e04d9aadd354d380f2bd40531d9737` is untouched, and the file's own
comment now records why the key must not come back.

**Every task body enters this checkout first.** devenv materialises a task as a
generated shell program that inherits the caller's working directory, and the
driver's runner enters with `--from path:<sdk>` from a scratch project, so
`cd consumer && zig build run` and `bash tools/check-provenance.sh` had no
`build.zig`, no `consumer/` and no `UPSTREAM.sha256` to work on. The bodies now
open with `cd "${sdk_root}"`, where `sdk_root = builtins.toString ./.` is the
module's own directory. `builtins.toString` converts the path instead of
interpolating it: a plain `${./.}` carries the path's store context and would
copy this whole SDK into the read-only store, and the copy is not the tree
`build.zig` and `UPSTREAM.sha256` describe. `$DEVENV_ROOT` is not used anywhere
— it is the scratch project, which is exactly what these bodies must not build
in — and a per-task `cwd` does not reach the generated program.

**Build output no longer lands in the checkout.** `sdk:build` and
`sdk:build:shared` pass an external `--prefix`, and every task passes an
external `--cache-dir`; both sit beneath `ZIG_LOCAL_CACHE_DIR`. That directory
is the caller's if one was exported, otherwise `$XDG_CACHE_HOME`, otherwise
`$TMPDIR`, and a task with none of the three set stops and says why rather than
writing `.zig-cache/` or `zig-out/` into a volume-mounted tree. `sdk:test`,
`sdk:smoke`, `sdk:check`, `sdk:check:shared` and `sdk:consumer` depend on no
install step in this graph, so they take the cache directory and no invented
flag. The two `sdk:package.*` tasks are unchanged deliberately: they run a
nested `devenv build` against the project the caller entered, and their
delivery output is a store path.

**Five task names lost their `.`, and the driver's two did not.** devenv 2.4.1
accepts alphanumerics, `:`, `-` and `_` in a task name and rejects anything else
before any shell runs, so `sdk:build.shared`, `sdk:test.release-safe`,
`sdk:check.shared`, `sdk:package.static` and `sdk:package.shared` are now
`sdk:build:shared`, `sdk:test:release-safe`, `sdk:check:shared`,
`sdk:package:static` and `sdk:package:shared`. The task count is unchanged and
so are the other six names — `sdk:build`, `sdk:test`, `sdk:smoke`, `sdk:check`,
`sdk:consumer`, `sdk:provenance` — and the last two are the ones the driver
runs, so lua's canonical integrity and consumer entries are exactly what they
were. The rejection itself is **not** a lua observation: `flake: false` stopped
these tasks from loading at all, so the names had never reached the parser. The
error text is the driver's, read out of another SDK's run in this same wave
(`Invalid task name: …`, exit 1, from `geographiclib-c`). These are dotted
*tasks*; nothing here renames a script, and no dotted script exists in this
file.

`sdk:provenance`'s command is still `bash tools/check-provenance.sh`, now run
against this checkout's own bytes. That is the same text the driver's canonical
map quotes for lua's integrity entry, and `sdk:consumer` remains the same entry
point for the consumer gate.

Landed in the same tree and unchanged by this entry, recorded here because it
belongs to the same source wave: entry 7's BSD translation front end and
macCatalyst `LUA_USE_IOS` row, and entry 8's `std.mem.eql` correction to
`Platform.kind`.

Not verified: **no gate has run against any of this.** Nothing here was built,
entered or executed. The seven devenv gates that failed in `20261004T175328Z`
are the ones that have to run again, and until one does, "the tasks now enter
this checkout" is a statement about a file and not a result.

## 10. 2026-10-04 — the consumer gate was checking the bundled graph in system
mode, and the error set claimed a check it never made

`PENDING-VERIFICATION`. Two corrections, both in the graph's own sources.
No native source, no header, no upstream test and no licence byte changed, and
no default moved.

**The nested consumer build now receives the mode this build resolved.**
`runConsumer` forwarded `-Dtarget`, `-Doptimize`, `-Dlinkage` and `-Druntime`
and nothing else, while `-Dsystem` is a real option here — the `system`
option in `build`, which supplies the default of
`b.systemIntegrationOption(lib_name, ...)`.
The driver's `before` run shows the consequence: `zig build consumer
-Dsystem=true` printed the outer build's own `system` line, reached the nested
build with `-Dlinkage=dynamic` and no mode at all, resolved **bundled** there
from `-Dsystem`'s absent default, compiled this tree's own `src/` — the same
twenty units the outer graph had just declined to compile — ran the consumer
against them, and exited 0
(`review-contract-probes/evidence/before-20261004T200332Z/index.json`).

The fix forwards the mode as the build runner's own switch,
`-fsys=lua`/`-fno-sys=lua`, not as a `-D` option: `b.systemIntegrationOption` is
fed by `-fsys=`/`-fno-sys=` (`lib/compiler/build_runner.zig:169-174`) and is
never an entry in the `-D` map, so a `-Dsystem` would have set the nested
graph's *default* and left the answer to that graph's runner. Both spellings go,
so the dependency resolves this build's answer through the shared `Graph`
(`lib/std/Build.zig:352`, `:116`, `:2731`). `consumer/build.zig` gains no
option: the same flag reaches its dependency unchanged, which is also why
`cd consumer && zig build run -fsys=lua` now states the same check directly.

The refusal is not made quieter. With the mode forwarded, a host with no
Lua 5.5 headers and no `-llua` stops where the outer build stopped and names
what is missing; the driver's `before` run records exactly that refusal on this
machine for the same mode entered on the consumer package directly. A missing
installed family is a boundary, and no system result may substitute for a
source-package result.

**The nested build carries its own job count and summary.** A `Run` step cannot
have a `-j` appended to it, so a nested build left to derive its own width takes
`cpu_count - 1` (`std/Io/Threaded.zig:1639`) and the consumer this step proves
compiles at a different width from the build that asked for it. It now passes
`-j8` and `--summary all`, keeps the `--cache-dir` subdirectory it already had,
and is still a nested `zig build` in `consumer/` whose run is the step's only
observable effect. No root contract changed: `devenv.nix`, `package.nix`,
`flake.nix` and `build.zig.zon` are untouched by this entry.

**`Error.FileError` stays, and its doc was what was wrong.** The set's preamble
said one tag per status code `src/lua.h:48-53` and `src/lauxlib.h:27` define
"because each of those is a condition this module checked", and that was false:
`LUA_ERRFILE` has one producer in the whole tree, `errfile` at
`src/lauxlib.c:774-783`, reachable only from `luaL_loadfilex`, which this
facade does not wrap. The tag and `statusOk`'s arm are kept — the set is the
shared C status vocabulary, a broader vocabulary is admissible, and removing a
public tag would break callers for no gain — and the claim is replaced by the
reachability that is actually true, named per method: `load`/`loadChunk` reach
`SyntaxError` and `MemoryError`; `pcall` and `resume` reach `RuntimeError`,
`ErrorInErrorHandler` and `MemoryError` — the last thrown from anywhere inside
the protected call and carried back out by `luaD_throw` (`src/ldo.c:125-128`,
`:1090-1099`) — and `resume`
reports `LUA_YIELD` as `RuntimeError`; `FileError` is reachable from none of
them and belongs to the raw `c.luaL_loadfilex` route. `Status` is unchanged and
still carries the full auxiliary namespace including `Status.file`. **No file
loader was added** to give the tag a producer; that would be a feature, not a fix.

Not verified: **no gate has run against any of this.** The three gates this
entry is waiting on are `zig build consumer` (bundled control),
`zig build consumer -Dsystem=true` (the mode that used to be silently
bundled), and the untouched `test`/`smoke`/`check` set to confirm nothing else
moved. Every statement above about what the nested build now receives is read
out of `build.zig`; the only observed thing is the `before` run above, and it
is about the tree before this change.

## 11. 2026-10-04 — what the nested consumer build receives, and the second hop
in the consumer package

`PENDING-VERIFICATION`. Four corrections in `runConsumer`, all in the graph's
own sources, plus the second hop in `consumer/build.zig`. No native source, no
header, no upstream test, no licence byte and no option default changed; no
new `-D` option, no new option on the consumer package, and no change to
`runConsumer`'s signature or to its single call site, the `consumer` step in
`build`.

**`-Dcpu` is forwarded, and it is a separate option from `-Dtarget`.**
`target.query.zigTriple` (`lib/std/Target/Query.zig:421`) writes the
architecture, the OS and the ABI; it carries no CPU model and no feature set
(`:421-423`), and `cpu` is declared in its own right by
`standardTargetOptionsQueryOnly` (`lib/std/Build.zig:1479-1483`). The helper
serialized the triple and stopped there, so the CPU half of the selection never
travelled: a `-Dcpu` the caller named was dropped on the way down, and a named
`-Dtarget` left the nested graph to resolve a model of its own rather than the
one this build was configured with. `-Dcpu` is now
`target.query.serializeCpuAlloc` (`lib/std/Target/Query.zig:530`), the same
pair `b.dependency` uses to report a `ResolvedTarget`
(`lib/std/Build.zig:454-459`). `serializeCpu` writes `native` for a query that
named no CPU and `baseline` for a cross query that named none, and
`Target.Query.parseCpu` (`:280-283`) recognises both, so the nested
`standardTargetOptions` resolves this build's selection rather than one of its
own. The triple is still serialized from `target.query` and not from
`target.result`; nothing about that changed.

**`-Druntime` is written in both values.** The line was
`if (runtime_loaded) run.addArg("-Druntime=true")`, so a cell whose dispatch is
the linked one was described by the *absence* of a flag and could not be told
apart from a flag that had been dropped on the way down. It is now
`-Druntime=true` / `-Druntime=false`, both always, which is the shape every
other value this helper forwards already had. The value the consumer program
branches on at comptime is the one its own `build.zig:41-48` reads and hands to
`b.dependency("lua", ...)`; no default of that option moved, and its `orelse
false` is still the standalone package's own.

**The nested build inherits the global cache this one was given.** Every other
switch on this command line was forwarded except that one. `b.cache_root.path`
was read and subdirectoryed for the nested graph's own manifest store; the
global cache — one shared store of packages and hashes — was left to be
resolved by the nested process, so a `--global-cache-dir` given to the outer
`zig build` was invisible to the nested one, which then fetched what this
graph already held and wrote outside the root this workspace approved. It is
now `if (b.graph.global_cache_root.path) |global_cache| {
run.addArg("--global-cache-dir"); run.addArg(global_cache); }` — two tokens,
which is the only spelling the runner parses
(`lib/compiler/build_runner.zig:1675`) and also the form the
compiler itself emits from a build script of its own
(`lib/std/Build/Step/Compile.zig:1478-1479`). It is inherited whole rather than
subdirectoryed, unlike the local cache above it, which keeps its existing
`<outer>/consumer` subdirectory: two build graphs must not write one manifest
directory, and one shared package store is the point. A null `path` still means
the current directory (`lib/std/Build/Cache/Directory.zig:13`), which is the
rule the local-cache block above already follows.

**The caller's own arguments now reach the nested build, behind `--`.**
`zig build consumer -Druntime=true -- --provider <path>` is a command the
consumer program documents (`consumer/src/main.zig:28-44`, with
`LUA_TEST_PROVIDER` as the other route), and this helper emitted no `--`, so
the words a caller typed stopped at this process: the outer runner collected
them into `b.args` and the nested command line never carried them. The `--`
follows every argument above it, because those are this package's bookkeeping
with the nested build and only what the caller typed belongs to the program;
`--` is where the runner stops parsing and keeps the rest
(`lib/compiler/build_runner.zig:428-430`).

**The second hop is in place, so the program's own arguments arrive.** The
nested graph collects everything after `--` into its own `b.args`, and
`consumer/build.zig` now hands that on: `if (b.args) |args|
run_exe.addArgs(args)` on the run step it builds from the executable. Without
that line `Step.Run` takes its arguments only from what was added to it
(`lib/std/Build/Step/Run.zig:19-20`, `:523-525`), so `-- --provider <path>`
entered the nested graph and stopped there, and the consumer program fell
through to `LUA_TEST_PROVIDER` instead. With no arguments the added call is
inert, because `b.args` is null, so `zig build consumer` without arguments is
unchanged by it either way.

**Re-read, and deliberately not re-opened.** The helper already forwarded
`-Dtarget` from `target.query`, `-Doptimize`, `-Dlinkage` as
`deliveredLinkage(target, linkage)` rather than as the option a caller typed,
the resolved system mode as `-fsys=lua` / `-fno-sys=lua` in both directions,
all five executor switches, `--libc-runtimes`, `-j8` and `--summary all`, and
`--cache-dir` as two tokens with the `<outer>/consumer` subdirectory. It is
still a nested `zig build` in `consumer/` whose run is always the step's only
observable effect, and the external matrix, not this build, still classifies
targets with no executor as build-only. The `zig build consumer` step's own
description, the module doc's entry-point list and every option in it are
unchanged.

Not verified: **no gate has run against any of this.** Nothing here was built,
entered or executed. The gates this entry waits on are `zig build consumer`
(bundled control), `zig build consumer -Druntime=true` (the value now stated in
both spellings), `zig build consumer -Dsystem=true` (unchanged, and the mode
whose forwarding entry 10 records), a `-Dtarget` cell with a named `-Dcpu` to
show the two arrive as one selection, and
`zig build consumer -Druntime=true -- --provider <path>` to show both hops of
the program's own arguments. Every statement above about what the nested build
now receives is read out of `build.zig`, `consumer/build.zig` and the pinned
`lib/std`; none of it is an observed result.

## 12. 2026-10-04 — the nested consumer build now inherits the install prefix
the caller named

`PENDING-VERIFICATION`. One correction in `runConsumer`, in the graph's own
sources. No native source, no header, no upstream test, no licence byte and no
option default changed; no new `-D` option, and no change to `runConsumer`'s
signature or to its single call site, the `consumer` step in `build`.

**The install prefix is handed on.** Every path on that command line was
forwarded except this one. `b.cache_root.path` and
`b.graph.global_cache_root.path` are both read, and `b.install_prefix` was not,
so the nested graph resolved a prefix of its own. It is now forwarded when
`b.install_prefix` differs from `b.build_root.join("zig-out")`, which is the
only case in which the caller named one at all, and a relative value is made
absolute against `b.graph.cache.cwd` before it is handed on: the step's
working directory is `consumer/`, so a relative `--prefix` would otherwise
resolve there instead of against this build's root. `DESTDIR` is deliberately
not forwarded, because the nested build inherits the environment this one ran
with. The shape is the one `tzdata/build.zig` already uses for its consumer
step, so there is one spelling of this relay in the workspace rather than two.

Nothing about the step's contract moved. It is still a nested `zig build` in
`consumer/` whose run is always the step's only observable effect, the
`--prefix` is placed before the `--` that separates the program's own
arguments, and no `devenv.nix`, `package.nix`, `flake.nix` or `build.zig.zon`
line changed.

What this entry does not claim: the nested command is `zig build run`, whose
`run` step depends on no install step, so this is a statement about the prefix
the nested graph resolves and not about a file observed under `consumer/`.

Not verified: **no gate has run against any of this.** Nothing here was built,
entered or executed. The gate this entry waits on is `zig build consumer
--prefix out`, with `out/` and `consumer/zig-out` read afterwards. Every
statement above is read out of `build.zig`; none of it is an observed result.

## 13. 2026-10-04 — the nested consumer route ran in all four configurations, and
the relay was read off the command line that ran

`SOURCE-CONFIRMED` from the driver's evidence index under the approved scratch
root, `nested-delivery-proof/evidence/20261004T220323250122Z-515d06adcbbf/index.json`.
Nine cases for this SDK, all nine as expected: eight semantic runs that exited 0
and one refusal that exited 1. Nothing in this entry is read out of a source
file; it is the command line the nested build was actually given, plus what the
consumer program printed.

| Case | Outer command | Result |
|---|---|---|
| `nested-default-linked-static` | `zig build consumer`, no option but the mode | 6/6 steps; the program's own "every answer matched the documented value" |
| `nested-default-linked-dynamic` | the same, shared delivery | 7/7 steps; the same |
| `nested-default-loaded-static` | the same, `-Druntime=true` and `-- --provider <path>` | 6/6 steps; the same |
| `nested-default-loaded-dynamic` | the same, shared delivery | 6/6 steps; the same |
| `nested-explicit-linked-static` | `-fno-sys=lua -Doptimize=Debug -Dlinkage=static -Druntime=false -Dtarget=x86_64-linux-gnu -Dcpu=baseline` | 6/6 steps; the same |
| `nested-explicit-linked-dynamic` | as above, shared delivery | 7/7 steps; the same |
| `nested-explicit-loaded-static` | as above with `-Druntime=true` and `-- --provider <path>` | 6/6 steps; the same |
| `nested-explicit-loaded-dynamic` | as above, shared delivery | 6/6 steps; the same |
| `nested-no-provider` | `-Druntime=true`, no provider named and none in the environment | **exit 1**, `error: NoProviderConfigured`, 4/6 steps with the program's own step the failed one |

What the driver read off the nested line in every one of the eight passing cases,
which is the point of the run rather than the program's output:

* `-Dtarget=x86_64-linux-gnu` and `-Dcpu=baseline` in the four explicit cases,
  each equal to what the caller named, so the CPU half of the selection is
  observed and not inferred. The mode rides the same line as
  `-fno-sys=lua`, with the plan's declared native flags matching what the
  nested line printed.
* `-j8` and `--summary all`.
* `--cache-dir` at `<outer cache>/consumer`, inside the cache root that row
  selected, and `--global-cache-dir` at the caller's global cache, inherited
  whole rather than subdirectoryed.
* `--prefix` at the prefix that row named, present and propagated, and not
  resolving inside this tree. That is entry 12's relay, now observed instead of
  read.
* In the four loaded cases the provider arrived as `-- --provider <path>` on the
  nested line. Every provider variable was excluded from the child environment in
  every case, `LUA_TEST_PROVIDER` among them, so what opened the object was the
  command line and not an inherited variable. That is both hops of the
  program's own arguments, observed.

`nested-no-provider` is the other half of the same statement: with no provider
named on either route, the consumer program refused by name and exited 1, and
the driver counted that refusal as the expected result rather than as a failure
of the gate.

Bounded by what was run. The four default cases record
`-Dtarget=native -Dcpu=native` without judging them, because a default row names
no selection to compare against. These nine cases say nothing about
`zig build check`, the published platform matrix, `-Doptimize=ReleaseSafe`, the
Nix or devenv outputs, the provenance script, or `cd consumer && zig build run`
entered directly, none of which is in them. This entry supersedes entries 11 and
12 where they say that no gate has run against the nested consumer route; their
source readings stand unchanged.

## 14. 2026-10-05 -- the consumer step installs a target this host cannot execute

`PENDING-VERIFICATION`. One decision in `runConsumer` and one private predicate,
both in `build.zig`. No native source, no header, no upstream test, no licence
byte, no option default and no consumer-side change; `-fsys=lua` /
`-fno-sys=lua`, `-Dtarget`, `-Dcpu`, `-Doptimize`, `-Dlinkage`, `-Druntime`, the
executor switches, `--libc-runtimes`, `-j8`, `--summary all`, both cache
directories, `--prefix` and `b.args` behind `--` travel exactly as before.

**The step no longer asks for a run it cannot keep.** It asked for `run`
unconditionally, and the nested `consumer/build.zig` run step is a plain
`addRunArtifact` with no `allowSkip`, so a foreign cell was a hard `failForeign`
rather than a skip. The sub-command is now `run` when `hostCanExecute` holds for
the selected target and `install` when it does not. `hostCanExecute` asks
`std.zig.system.getExternalExecutor` -- the predicate `std.Build.Step.Run`
applies to the artifact it is about to spawn -- carrying this build's own
`b.enable_*` switches in `allow_*`, so the decision here and the nested run
cannot disagree. Its `.qemu` arm adds `Run`'s own second gate, under which a
cross GNU libc target given no `--libc-runtimes` installs instead. The shape is
the one `inchi`, `lmdb`, `random123`, `s2geometry` and `spglib` already use.

**What an install is.** `consumer/zig-out/bin/lua-consumer` under the nested
build's own prefix, or `<prefix>/bin/lua-consumer` when the caller named one.
The consumer program is not executed on that cell, so the result is compile
evidence and never a semantic pass. The negative branch means "no enabled
executor for this target", not "no library": `refuseTarget` and
`deliveredLinkage` still stop the outer build exactly where they did.

Not verified: **no gate has run against any of this.** The gates this entry
waits on are `zig build consumer` (unchanged, native), `zig build consumer
-Dtarget=aarch64-linux-gnu` with no `-fqemu` (installs; failed before), the same
with `-fqemu --libc-runtimes <dir>` (runs), and the same with `-fqemu` and no
runtimes directory (installs).

## 15. 2026-10-05 -- system mode gives its one `lua.pc` query to the translation,
which is the step that needed the headers

`PENDING-VERIFICATION`. Four changes inside `addGraph` in `build.zig`, all of
them on the `-fsys=lua` branch: `translate.linkSystemLibrary` is now called
once, on the `TranslateC` step, and the second call on the module is gone. No
native source, no header, no upstream test, no licence byte, no option default
and no consumer-side change; `lua/consumer/build.zig` needed no edit.

**The condition.** In system mode `translate_include` is null, so the
`zig translate-c` line carried no header search path, and `zig/translate.h:69-71`
includes `<lua.h>`, `<lauxlib.h>` and `<lualib.h>` with angle brackets. They fell
through to the target's default search -- the host's own Lua -- while the module
asked `lua.pc` for the library. A module's pkg-config `Cflags:` reach that
compilation and its link line, never the separate `TranslateC` step, so system
mode had a library and no declarations for it.

**The fix.** One `linkSystemLibrary` on the translation. It carries
`-I${includedir}` to `zig translate-c`, and `createModule` copies the entry onto
the `c` module, so the exported `dep.module("lua")` and every dependent bind the
same prefix the declarations were read from. `Compile` dedups by library name,
so the removed call would only have re-emitted the same `-I`.

Not verified when this entry was written: **no gate had yet run against any of
this.** Entry 16 records what a later gate did and did not observe, and it does
not move this entry's `PENDING-VERIFICATION`.  The gate this entry names is
`zig build consumer -fsys=lua -Dtarget=x86_64-linux-gnu` under a scoped
`PKG_CONFIG_PATH` and `PKG_CONFIG_LIBDIR`, watching for `zig/translate.h`'s
`'lua.h' not found` to stop. The `.preprocessed` route (NetBSD and OpenBSD only)
is unchanged and still resolves those names through the target's own search,
because `preprocessedAggregate` runs `zig cc -E -dD` before any `TranslateC`
flag exists; GMP's system branch makes the same statement. Bundled, cross-target
and `-Druntime=true` configurations take the new `if` as false and are unchanged.

## 16. 2026-10-05 -- the 53-cell matrix in `README.md`, and what the system-mode gate did and did not show

`SOURCE-CONFIRMED` for the source reading; the numbers are read off receipts
another gate wrote.  No build, test, smoke, check or provenance run was executed
for this entry.  No native source, header, upstream test, licence byte or
consumer-side file changed, and no option default moved.

**The matrix.**  `README.md` gained a subsection, "The source-bound 53-cell
matrix and baseline, 2026-10-04/05": 53 cells, `pass 20`, `build_only 30`,
`build_fail 3`, run exit 1, from
`resume-8-evidence/20261004T221720228710Z-45046/lua-53-target-8.json`; the
compile-only baseline `baseline-lua-check`, exit 0 and `failed: false`, from
`baselines-and-configs/20261005T014547Z-797a73f2/`; 8 of 8 native cells from
`native-final-evidence/20261004T233628757747Z-69351/run.json`; and 8 of 8
own-provider loaded cells from
`loaded-final-evidence/20261004T232823091897Z-23133/run.json`.  `build_only` is
compiled-not-run and is stated as coverage, never as a pass.  The "Published
platform matrix" row of the pending table moves from `PENDING-VERIFICATION` to
`OBSERVED` on that epoch, with the replay against the current source still owed.

**The three red cells are two different things.**  Two are the BSD translator —
`aarch64-netbsd` and `aarch64_be-netbsd`, both stopping at
`lua-translate.zig:1584:43: error: use of undeclared identifier '__int128_t'` —
and one is `wasm32-wasi`, which is this build's own deliberate refusal printed
before a compiler is invoked.  They are not three of a kind, and the README now
names which two are the BSD translator and which one is this build's own
refusal.  The NetBSD cause was **not re-derived** for this matrix and is
recorded as an open item rather than a conclusion.

**System mode, bounded to what the observer caught.**  Entry 15 put the single
`lua.pc` query on the `TranslateC` step, so the `-I${includedir}` reaches
`zig translate-c` and the declarations and the library come from one prefix.  A
driver gate has since run that route: it **exited 0 with every answer matched**,
which is the semantic result.  The diagnostic that would show *which* `lua.h`
the translation read — the one that distinguishes the pkg-config `includedir`
from the host's own Lua — was not captured, so that half is unproven.  **This
is an observer gap, not a reported failure of this SDK**, and it is not evidence
for or against entry 15's fix.  Entry 15 stays `PENDING-VERIFICATION`; a gate
that records both the answers and the selected header is what closes it.

**Bound.**  The 53-cell run predates the later build-graph, header and
normalization edits, entry 15 among them; its `source_unchanged: true` speaks
only to its own run.  No earlier entry's status moved except the sentence in
entry 15 that said no gate had yet run, which is amended in place above to say
when it was written rather than what is true today.