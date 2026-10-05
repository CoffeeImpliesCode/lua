# Fork notes

Numbered working notes for this SDK. Each one states where the fact came from
and what it does **not** prove. A few gates have since run — the linked static
route, the shared delivery and the runtime-loaded route, each described in
[`CHANGELOG.md`](CHANGELOG.md) entry 6 and in README.md's matrix — and nothing
here is a receipt for any gate that has not.

## 1. This import has no upstream commit identity

Lua's working sources live at `<https://www.lua.org/git/lua.git>` and on
GitHub, but what is imported here is the signed-by-digest release tarball. There
is therefore no commit SHA to record, no history to keep, and no patch series to
re-apply — only `UPSTREAM.sha256`, which pins the 75 files individually.
Re-syncing to another release means re-downloading, checking the published
digest, replacing the files and moving the digests in one change.

## 2. The tarball has no test suite, and one must not be fetched to fake it

`src/Makefile:69-70` defines the whole of upstream's `test` target as
`./$(LUA_T) -v`. Lua's real test library is not in a release tarball. So this
SDK cannot claim to build or run an upstream suite, and no step may download one
at build time: a fetched suite is a different source tree from the pinned
release, with no recorded digest, and it would make the "native source is
unmodified" claim unverifiable.

**Bound to:** this project, and the same rule applies to any tarball-only import
in this workspace.

## 3. Nothing in the native C is generated, and nothing should be invented to
generate

No `configure`, no generated header, no generated table. `src/ljumptab.h` — the
interpreter's dispatch table — is a checked-in source file whose own comment
gives the `sed` command upstream uses to refresh it
(`src/ljumptab.h:21-25`). A build graph that generated a copy of it would create
a second source of truth for the VM's opcode order.

The build graph does write three files, and none of them is a second source of
truth for the C: `lib/pkgconfig/lua.pc` — which upstream has no equivalent of,
its `pc` target only echoing the values (`Makefile:96-101`) — the ELF version
script, and, only under `-Druntime=true`, the dispatch, which is generated from
the translation that same build just produced. Nothing is generated into
`src/` or `doc/`, and `tools/check-provenance.sh` fails if anything appears
there.

The platform configuration is the only per-target input, and it is chosen from
the target being built (`luaconf.h` reacts to `_WIN32`, `LUA_USE_LINUX`,
`LUA_USE_POSIX`, `LUA_USE_DLOPEN`, `LUA_32BITS`), never from the build host.

## 4. The external ABI a runtime-loaded provider must satisfy

`-Druntime=true` resolves `lua_*`, `luaL_*` and `luaopen_*` from a chosen shared
object at runtime. Resolving those symbols proves the library has the names; it
does not prove the consumer and the provider agree about anything else. What
they must agree about, all of it read out of the headers:

1. **Scalar widths.** `luaconf.h:136-137` makes `lua_Integer` 64-bit
   `long long` and `lua_Number` `double` by default, but
   `LUA_INT_TYPE`/`LUA_FLOAT_TYPE` and `LUA_32BITS` (`luaconf.h:143`,
   `162-182`) change both. A provider built with a different configuration is a
   different ABI even though every symbol name matches.
2. **Layout.** `Instruction`, `lua_Debug` (`lua.h:487-507`) and the internal
   structures the public headers expose as pointers.
3. **Configuration macros.** `LUA_USE_APICHECK` (`luaconf.h:691`) adds API
   checks in the provider; `LUA_COMPAT_GLOBAL` (`luaconf.h:344-345`) and the
   other `LUA_COMPAT_*` switches change library behaviour. Matching names do not
   imply matching behaviour.
4. **Allocator.** `lua_Alloc` is a caller-supplied callback
   (`lua.h:125`, installed by `lua_newstate`, `lua.h:163`, readable through
   `lua_setallocf`, `lua.h:379`). Memory Lua allocated must be released through
   the same state, and a wrapper that hands Lua a Zig allocator has crossed a
   real ownership boundary.
5. **Binary chunks.** Precompiled chunks are rejected on load unless the sizes
   and constants match: `lundump.c:380-388` checks `LUAC_VERSION`,
   `LUAC_FORMAT`, the `LUAC_DATA` literal and the sizes of `int`,
   `Instruction`, `lua_Integer` and `lua_Number`. A `luac` artifact is portable
   to the configurations that agree on all five, and to nothing else.

What the loader can actually observe is narrower, and it is worth keeping the
two lists apart. `runtime/library.zig` checks five things before it publishes a
table: `lua_version` answering this header's `LUA_VERSION_NUM`; the resolved
`lua_ident` address beginning with `$LuaVersion:` (`lapi.c:35-37`);
`luaL_newstate` returning a state that `lua_close` releases, which exercises the
provider's allocator and teardown path; a fresh state answering `lua_gettop ==
0`; and `2^53 + 1` round-tripping through `lua_pushinteger`/`lua_tointegerx` as
an integer. Items 1 and 3 above are therefore *checked*; items 2, 4 and 5 are
obligations this repository states and cannot enforce. `luaL_checkversion_`
(`lauxlib.h:46`) is upstream's own version-and-size check and is deliberately
not called at load time: it raises a Lua error rather than returning one, and
outside a protected call that reaches the panic handler, which a loader cannot
turn into a `ValidationFailed`.

## 5. Data symbols are pointers into the provider, never copies

The only data symbol declared in a public header is `lua_ident`, declared at
`lua.h:157` and defined at `lapi.c:35`; it is the `$LuaVersion$/$LuaAuthors$`
string a host program reads. A runtime table that copied those bytes into its
own storage would report the build-time provider's identity regardless of what
was loaded, so the resolved address must stay live. The facade's
`version_ident()` is the observable consequence: it reads the provider's own
`lua_ident` in both the linked and the loaded configuration, so the identity a
program prints is the identity of the object actually in use.

The translation expresses this as an `@extern` of the declared pointer type,
which is what makes "live" mechanical rather than a convention: the value is an
address resolved at load time, not a buffer this process owns. The runtime-loaded
run printed the loaded object's own banner
(`$LuaVersion: Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio …`), which
is the only evidence that could distinguish the two designs — a copied string
would have printed the build-time provider's bytes instead.

Two more data objects exist in the shared object but are provider-internal and
are not part of any public contract: `luai_ctype_[UCHAR_MAX + 2]`
(`lctype.c:28`) and `luaP_opmodes[NUM_OPCODES]` (`lopcodes.c:22`), both behind
`LUAI_DDEF`.

## 6. Lua 5.5 and LuaJIT's 5.1 are not interchangeable

This SDK pins 5.5.1. The public function names are largely stable back to 5.1,
which is exactly the trap: `lua_ident`'s `$LuaVersion$` string, the numeric
layout chosen by `luaconf.h`, and the `LUAC_VERSION` check all disagree between
the two families, so a 5.1-shaped provider resolved against 5.5 headers passes a
name check and fails at the first structure layout.

The runtime loader does not leave that to the caller to discover:
`runtime/library.zig` validates the family and **refuses** a provider whose
`LUA_VERSION_NUM` is 501 — LuaJIT 2.1 — while accepting 505. A refusal is the
right shape here because the alternative is a process that crashes later, in
Lua's own code, for a reason that looks like a memory bug.

**Bound to:** the loaded route. The linked route cannot make this mistake,
because it links against the library it was compiled with.

## 7. Linkage policy, soname and the one target that has no shared object

Upstream's `Makefile:44` installs `liblua.a` only. Static is therefore this
fork's preserved default and `-Dlinkage=dynamic` is the added variant, not a
change of policy. Both variants install the same closure; only the artifact kind
differs.

The shared object's version is 55, not "5.5". `src/Makefile:132-135` builds
`lua55.dll` for mingw, and that 55 is the only ABI number upstream states
anywhere, so the file is `liblua.so.55.5.1`, the soname is `liblua.so.55` and
the unversioned link name is `liblua.so`. "5.5" is not a soname and must not
appear as one.

**Named omission: Solaris' upstream recipe passes `-D_REENTRANT`** and this
build does not. `src/Makefile:139-141` is the only place it appears. There is
no observed failure behind either choice, so this is recorded as a deliberate
omission rather than as a fix, and it is the first thing to revisit if a
Solaris or illumos row in the published matrix ever goes red.

**`wasm32-wasi` has no shared delivery.** The target has no dynamic linker, so
`-Dlinkage=dynamic` is refused with a message naming the target rather than
silently substituted with an archive; the static and default builds are what
cover that row.

## 7a. The export surface is a namespace, not a list

The public contract is 156 functions and one data object: 98 `LUA_API` in
`lua.h`, 47 `LUALIB_API` in `lauxlib.h`, 1 `LUALIB_API` and 10 `LUAMOD_API` in
`lualib.h`. The earlier shape of this note described a generated version script
that enumerated exactly those, which is a second declaration convention: it
cannot survive a header that gains a function, and it says nothing about what a
caller should expect when it does not.

What replaced it is the namespace itself. On ELF the version script exports
`lua_*`, `luaL_*` and `luaopen_*` and marks everything else `local`, so the 156
functions and `lua_ident` are exported because they are Lua's public names, not
because someone listed them. On Windows `LUA_BUILD_AS_DLL` gives `LUA_API` its
`__declspec(dllexport)` (`src/luaconf.h:305-311`) and a generated module
definition file adds the single entry that macro cannot reach — `lua_ident
DATA` — because `src/lua.h:157` declares that object without `LUA_API`. On Darwin
and COFF the shared object also exports Lua's internal symbols, since `LUA_API`
is plain `extern` outside Windows (`src/luaconf.h:315`) and no Mach-O
equivalent can be relied on here.

Observed on the delivered object: `nm -D` reports 157 defined dynamic symbols —
99 `lua_` (98 `LUA_API` plus `lua_ident`), 48 `luaL_` (47 plus the one in
`lualib.h`) and 10 `luaopen_` — and no `luaS_*`, `luaC_*`, `luaH_*` or other
internal name. A count is not a proof of correspondence, which is why §4 states
the ABI obligations separately from the export list.

**Bound to:** ELF targets get a clean export surface by construction; Darwin
and Windows consumers must select by name and must not treat a resolved symbol
as evidence that it is API.

## 7b. One version, checked at configure time

`build.zig` refuses to configure unless `build.zig.zon`'s `.version` equals the
5.5.1 read out of `src/lua.h:20-22`. That is what keeps the package manifest,
the `lua.pc` `Version:` field and the shared object's file name from describing
three different releases.

## 7c. Darwin deliberately does not use `LUA_USE_MACOSX`

`src/luaconf.h:79-83` turns `LUA_USE_MACOSX` into `LUA_USE_READLINE`, which
makes `src/lua.c:462-471` include `<readline/readline.h>` and require
`-lreadline`. Using it would turn readline from an optional runtime `dlopen`
into a link-time dependency of the interpreter. The build uses `LUA_USE_POSIX`
and `LUA_USE_DLOPEN` on Darwin instead, so `lua.c` still tries to `dlopen`
`libreadline` at startup and still falls back to `fgets`.

## 7d. `zig build`, `zig build install` and packaging are one step

Zig 0.16.0's default top-level step is itself named `install`
(`lib/std/Build.zig:298-302` in the pinned compiler: `install_tls` carries
`.name = "install"` with the base id). Bare `zig build`, `zig build install` and
`package.nix`'s `zig build install --prefix "$out"` therefore run the same
step, and it is the step the library artifact, both programs, the five
headers, `lua.pc`, both man pages and the nine licence records are bound to.

That is worth knowing for a reason beyond the naming: an `addInstallFile`
return value that is dropped is a step that never enters the graph, so a
missing `lua.pc` or licence file would install silently incomplete **and exit
zero**. Every install call in this build is bound explicitly for that reason.
An exit code from an install is therefore necessary but not sufficient evidence
that the closure is complete; `find $out` is the check.

## 7e. What the translation carries, and where the load boundary still bites

An earlier version of this file, and of both READMEs, said that `c` carried no
macros. That was wrong, and the correction matters because it changes what a
caller can write.

`translate-c` translates the headers' function-like macros into wrappers over
the entry points they expand to, with upstream's operands. `c.lua_pop(L, n)`
exists and is `lua_settop(L, -(n)-1)` (`src/lua.h:396`);
`c.luaL_openlibs(L)` exists and is `luaL_openselectedlibs(L, ~0, 0)`
(`src/lualib.h:62`), as do `lua_call`, `lua_pcall`, `lua_newtable`,
`lua_tostring`, `lua_tonumber`, `lua_tointeger`, `lua_pushcfunction`,
`lua_pushglobaltable`, `lua_register`, `lua_pushliteral`, `lua_isnil`,
`lua_getextraspace`, `lua_resetthread`, `luaL_checkstring`, `luaL_typename`,
`luaL_dostring`, `luaL_newlib` and `luaL_newlibtable` — every one of them a
`pub inline fn` in this build's translation. `luaL_newlib` in particular is a
comma expression of three calls (`src/lauxlib.h:135-136`) and lowers anyway:
Aro emits the leading calls as discarded statements and keeps the last as the
result. `lua_absindex` (`src/lua.h:177`) and `lua_xmove` (`src/lua.h:185`)
look like macros in older Lua and are plain functions here.

Where a body does *not* lower, the translation says so rather than dropping the
name: `c.luaL_addchar`, `c.luaL_addsize` and `c.luaL_buffsub`
(`src/lauxlib.h:201`, `205`, `207`), `c.lua_str2number` (`src/luaconf.h:457`)
and `c.lua_getlocaledecpoint` (`src/luaconf.h:644`) are `pub const` values of
`@compileError`. A caller who wants one of those writes the expansion; that is
also why the `luaL_Buffer` section of the raw route is the buffer's own
declaration plus `pushlstring`, not the mutating macros. The three real C
variadics — `lua_pushfstring` (`src/lua.h:252`), `luaL_error`
(`src/lauxlib.h:76`) and `lua_gc` (`src/lua.h:360`) — arrive as Zig variadics,
and `lua_pushvfstring` (`src/lua.h:250`) arrives with its `va_list`.

What does **not** change is the boundary. A macro is not a symbol: the
delivered `liblua.so.55.5.1` exports no `lua_pop`, only `lua_settop`. So the
facade names the declarations directly (`discardError` → `lua_settop`, `call` →
`lua_callk`, `register` → `lua_pushcclosure`), the runtime table has no macro
name to resolve, and the loader's own teardown path spells the expansion out by
hand — `runtime/library.zig` calls `lua_settop(state, -2)` where a C
translation of that code would have written `lua_pop`.

`lua_ident` is the one declaration whose *value* is the provider's address: the
translation binds it as an `@extern` of the declared pointer type, and the
generated dispatch has to route that address rather than a copy of it. That is
the shape the canonical runtime generator now handles — an `Aro` `pub const`
whose initializer is an `@extern`, routed with the declared pointer type so the
dispatch never takes a direct native link on the symbol it is supposed to
resolve at run time.

**Bound to:** these are properties of the translation `zig/translate.h`
produces and of the shared object this graph builds. Neither is a claim about
any other Lua build, and none of it is proof that a provider is ABI-compatible —
§4 is the list of what compatibility actually requires.

## 7f. The BSD cells read the C library through the compiler, not through Aro

`zig translate-c` parses C with Aro, and Aro preprocesses as well as parses, so
the aggregate header can be read either way round. `aggregateRoute` decides per
target and `preprocessedAggregate` is the extra front end; NetBSD and OpenBSD
take it, every other target keeps the route it had. This is ERFA's pattern, and
the reasons are the same in kind: not a preference for one preprocessor, but
three header behaviours in this toolchain's bundled C libraries that Aro cannot
read and the compiler beside it reads without difficulty.

`src/lauxlib.h:13`'s `<stdio.h>` is the door all three come through, and the
aggregate's only system headers are `<stdarg.h>`, `<stddef.h>`, `<limits.h>`,
`<stdint.h>` and `<stdio.h>` (`src/lua.h:12-13`, `src/luaconf.h:11-12`,
`src/lauxlib.h:12-13`). All lines below are `SOURCE-CONFIRMED` from the pinned
compiler's own `lib/libc/include`.

| Target | What Aro meets | Where |
|---|---|---|
| NetBSD, whole family | `__END_DECLS` routed through `_Pragma` | `generic-netbsd/sys/cdefs.h:411-413`, `:431-432`; `generic-netbsd/stdio.h:149` |
| OpenBSD 32-bit | `size_t` declared twice, to two different types | `x86-openbsd-none/i386/_types.h:123`, `arm-openbsd-eabi/arm/_types.h:123`, `generic-openbsd/stdio.h:49-52`, `lib/compiler/aro/include/stddef.h:8` |
| OpenBSD MIPS64 | `#error` because neither endian predefine is set | `generic-openbsd/stdio.h:46` → `sys/types.h:45` → `sys/endian.h` → `sys/_endian.h:36-40` → `generic-openbsd/mips64/endian.h:32-41` |

The OpenBSD `size_t` row is the one that is 32-bit-only, and that is worth
keeping: `unsigned long` and the compiler's own `__SIZE_TYPE__` are the same
type on every LP64 target, and C permits a typedef name to be redeclared to the
type it already has. On `x86-openbsd-none` and `arm-openbsd-eabi` they are not
the same type, so the second declaration is a conflict. That is why the
condition is the OS tag and not "32-bit OpenBSD plus mips64": one diagnosis per
row would be a second convention, and a triple list would silently stop
covering the next architecture.

What the extra front end is not allowed to be: a substitute. It runs
`b.graph.zig_exe cc -E -dD` — the same pinned compiler, for the same target,
with the same `-I src`, the same `-D` list and the same `-std=gnu99` the 32 core
units are compiled with — and Aro parses what that wrote. No predefine was added
to make a header answer; the endian macros in particular come from the compiler
that already compiles the core for that target. `-dD` is what keeps the
translated constant set intact (`lualib.h:62`'s `luaL_openlibs`, `lua.h`'s
`LUA_T*` family, and the `c.LUA_VERSION_NUM` / `c.LUA_MULTRET` bindings in
`zig/root.zig`), and `-MD`/`-MF` makes the headers the command discovered this
step's own inputs.

**Two boundaries this does not close.** The LP64 non-MIPS OpenBSD cells have no
diagnosed cause of their own; they take the same front end because it is the
one that reads the C library the compiler compiles against, not because anyone
diagnosed them. And `generic-freebsd` has the same shape under a different
guard (`_SIZE_T_DECLARED`, `generic-freebsd/stdio.h:46-49`): no FreeBSD cell was
reported failing, so no FreeBSD row was changed.

**Bound to:** Zig 0.16.0's bundled `generic-netbsd` and `generic-openbsd`
headers, and to the two `zig translate-c` shapes described above. A different
toolchain version with different headers is a different set of rows, and the
table is the thing to re-read, not this conclusion.

## 7g. macCatalyst: upstream's own arm, and what it cannot do

`src/loslib.c:133-140` already carries the arm this target needs. With
`LUA_USE_IOS`, `l_system` is `((cmd) == NULL ? 0 : -1)` instead of
`system(cmd)`, under upstream's own comment — "Despite claiming to be ISO C,
iOS does not implement 'system'". `os_execute` calls it at `src/loslib.c:147`,
and this toolchain's Darwin libc declares `system` with `__IOS_PROHIBITED`
(`lib/libc/include/any-darwin-any/_stdlib.h:205-208`), which
`Availability.h:327` turns into `__attribute__((availability(ios,unavailable)))`.

So the fix is a configuration macro, not code: `Platform.forTarget` gives
macCatalyst `LUA_USE_IOS`, which `src/luaconf.h:86-89` expands to exactly the
`LUA_USE_POSIX` and `LUA_USE_DLOPEN` the Darwin row already used and to nothing
else. `LUA_USE_IOS` occurs in three places in the imported source —
`src/luaconf.h:86`, `src/Makefile:121`, `src/loslib.c:134` — so that is the
whole of what it changes on a Catalyst target.

**What was rejected, and why.** `LUA_USE_MACOSX` is not the answer: §7c's
reason applies unchanged, because `src/luaconf.h:79-83` turns it into
`LUA_USE_READLINE` and `src/lua.c:462-471` then requires `-lreadline`. A
mandatory readline dependency is not something a `system()` repair may buy.
`posix_spawn` is not the answer either, and not because it is unavailable —
because it is not what upstream wrote. Writing the C that spawns a child here
would be a substitute for a platform decision rather than a configuration of it,
and it would contradict `src/loslib.c:136` in upstream's own bytes.

**The boundary, stated.** On macCatalyst this build's `os.execute("cmd")`
answers `nil, "exit", -1` — `stat` is `-1` and `errno` is `0`, so
`src/lauxlib.c:291-305` takes its second branch — and `os.execute()` answers
`false`, upstream's own statement that there is no shell. `os.execute` is the
one standard-library function this build cannot provide on macCatalyst. Nothing
else is affected: `os.time`, `os.date`, `os.clock`, `os.getenv`, `os.remove`,
`os.rename` and `os.tmpname` are the same code they are on every other target.

The sibling Darwin tags — `.ios`, `.tvos`, `.watchos`, `.visionos` and
`.driverkit` — share the shape (`__IOS_PROHIBITED` and its per-platform
siblings are in the same `_stdlib.h` declaration), and `LUA_USE_IOS` would cover
them. No cell on those tags was reported failing, so none of them was changed;
that is a boundary, not a claim that they build.

**A label is still code.** The `LUA_USE_IOS` row needed `Platform.kind` to stop
naming a one-macro row by its *length* — the Catalyst row has one macro and
expands to two definitions, so `macros.len == 1` would have printed Linux's name
for it. The fix compared the macro's name instead, and it did not compile:
`platform.macros[0][0]` is a `[]const u8` and Zig has no `==` for slices, so the
build script failed on every configuration, host included. `std.mem.eql(u8, …)`
(`lib/std/mem.zig:732`) is the correct spelling. The lesson is narrower than
"more Zig": the broken line named a *label*, not a platform decision, and it
broke because the change's whole purpose was a label.

**Bound to:** the `system()` availability annotation in Zig 0.16.0's bundled
Darwin libc, and to `src/loslib.c:133-140` staying as upstream wrote it. If
upstream's `LUA_USE_IOS` arm ever grows a real implementation, this note is what
has to be revisited.

## 8. Packaging decisions worth keeping

* `package.nix` is one derivation, not two. `linkage` is an argument; the flake
  and the devenv outputs choose among its values. A `{static,shared,default}`
  attribute set inside `package.nix` would be a second convention.
* The cross-build refusal compares `stdenv.buildPlatform.system` with
  `stdenv.hostPlatform.system`. Both are pure; `builtins.currentSystem` is not
  evaluable in a sandbox and is not used.
* `package.nix` copies nothing and generates no `.pc`. Upstream's `make pc`
  (`Makefile:96-101`) only echoes the values a `.pc` would contain, so the file
  is a fork decision and it belongs to the build graph, where the artifact it
  describes is the one that was actually produced.
* `dontInstall` is deliberately **not** set: it is what disables a real install
  phase. `dontConfigure` and `dontBuild` are, so the setup hook cannot run a
  second, differently-flagged build before the one in `installPhase`.

## 8a. A task body runs in the caller's directory, `zig build` installs into
it, and a task name cannot carry a `.`

Two independent defects made every canonical devenv gate for this SDK fail.
Either one alone is enough, and the second was invisible in the run that
observed the first.

**`devenv.yaml` said `flake: false`, which took `lib` away from the nixpkgs
input.** That one is observed, not inferred: the driver's run
`nix-acceptance-20261004T175328Z` recorded the same error in all seven lua
devenv gates, exit 1 each — `Failed to get attribute 'config.cachix.enable'`
at `<project>/.devenv/bootstrap/bootstrapLib.nix:430:9`, then `lib =
nixpkgs.lib` at `:54:13`, ending in `error: attribute 'lib' missing`.
`flake: false` tells devenv to read the input as a plain source tree, a plain
source tree has no `lib`, and devenv's own bootstrap needs `lib` before it can
evaluate anything else. The pin is untouched: the whole contract of
`devenv.yaml` is its one `url:` line, and the key that broke it is deleted.

**A task body runs in whatever directory the caller was in.** devenv
materialises a task as a generated shell program and that program inherits the
caller's working directory; a script is the same. The driver's runner enters
with `--from path:<sdk>` from a scratch project directory, so
`cd consumer && zig build run` and `bash tools/check-provenance.sh` would run
where there is no `build.zig`, no `consumer/` and no `UPSTREAM.sha256`. The
run that observed the bootstrap failure never reached either body, so this
one is `SOURCE-CONFIRMED` from the SDK's own `devenv.nix` text plus the
`/nix/store/...-sdk-consumer: line N:` prefixes the driver's receipts show for
the other SDKs that got that far. `$DEVENV_ROOT` is that scratch project, and
a per-task `cwd` does not reach the generated program, so neither is a repair.

The repair is one binding and one line per body:

```nix
sdk_root = builtins.toString ./.;
```

`./.` is a path literal relative to the file that names it, so it is this
checkout wherever it is. `builtins.toString` converts the path rather than
interpolating it into a string, and that is the part that matters: a plain
`${./.}` carries the path's store context, which copies this whole SDK into
the read-only store, and the copy is not the tree `build.zig` and
`UPSTREAM.sha256` describe. No host path is written in the file.

**And `zig build` writes into the directory it runs in.** Zig's default
top-level step *is* the install step (§7d), so `sdk:build` installs into
`zig-out/` and every `zig build` writes `.zig-cache/` — both inside the
checkout, on a volume mount whose file set and mtimes the driver digests
before and after each gate. The two installing tasks therefore pass an
external `--prefix`, and every task passes an external `--cache-dir`, both
beneath `ZIG_LOCAL_CACHE_DIR`. That directory is the caller's if one was
exported, otherwise `$XDG_CACHE_HOME`, otherwise `$TMPDIR`; with none of the
three set, a task stops and says why instead of filling the tree. `test`,
`smoke`, `check` and `consumer` depend on no install step in this graph's own
`dependOn` wiring, so they take the cache directory and no invented flag.

The two `sdk:package.*` tasks are the only bodies that do not change
directory, and that is deliberate: they run a nested `devenv build`, which
reads the project the caller entered — the scratch project holding `.devenv/`
and `devenv.lock` — and their delivery output is a store path, not a directory
in this tree.

And a third thing about tasks, which was not a defect until the first two were
out of the way: devenv 2.4.1 accepts alphanumerics, `:`, `-` and `_` in a task
name and rejects anything else before any shell runs. Five names carried a `.`
— `sdk:build.shared`, `sdk:test.release-safe`, `sdk:check.shared`,
`sdk:package.static`, `sdk:package.shared` — and are now spelled with a second
`:`. The task count and the other six names are unchanged, including the two
the driver runs, `sdk:consumer` and `sdk:provenance`. Nothing here renames a
script: this file has none, and a dotted *script* name is legal where a dotted
task name is not.

This one is the weakest of the three claims, and the label matters: **the
rejection was not observed for this SDK.** `flake: false` stopped these tasks
from loading at all, so their names never reached the parser. The error text
(`Invalid task name: …`, `namespace:name`, alphanumerics `:` `-` and `_`) is
the driver's, read out of `geographiclib-c`'s row in the same run, and it is
that observation, plus devenv 2.4.1's own rule, that these five names are
corrected on rather than carried forward.

Not verified: **no devenv command has been run against this file since the
change.** The seven gates that failed in `20261004T175328Z` are the ones that
have to run again. Until they do, every statement above about what a task now
does is `SOURCE-CONFIRMED` from this file's text and the bootstrap error the
driver recorded — not a result.

**Bound to:** devenv 2.4.1's task materialisation, and a runner that enters
with `--from path:<sdk>` from outside the SDK. That runner is right and stays:
the same run showed `.devenv/` and `devenv.lock` only in the scratch project,
and `repo:untouched` passed 18/18 with identical file sets. Under a runner
that already `cd`s into the SDK this change is redundant rather than wrong;
under a devenv with a real per-task `cwd` it can be revisited.

## 9. Open, for the driver

1. Three configurations have been run — linked static, the shared delivery and
   the runtime-loaded route against an installed provider — and the rest of
   README.md's pending table is still unrun. Both runnable routes carried the
   whole 19-test suite plus the smoke, so the loaded route is exercised by the
   same assertions as the linked one and not only by the example. The notes
   above describe source and those receipts, not a completed gate set; the four
   runtime/linkage combinations, Windows, ReleaseSafe, the six compile-only
   targets and the published platform matrix are all still open.
2. The per-target expectation for the six compile-only targets and the full
   published matrix comes from Lua's own platform support, read out of
   `luaconf.h`, and is to be reported from the driver's runs rather than
   predicted here. Two boundaries are already known and are not predictions:
   `wasm32-wasi` has no shared delivery (§7), and the export list is only clean
   on ELF (§7a).

   The BSD translation front end (§7f) and the macCatalyst `os.execute` boundary
   (§7g) are in the same category: corrections landed on the driver's reported
   failures, not on runs these notes performed. Nothing here has been built.
3. `devenv.lock` does not exist and was not invented, because `devenv.yaml`
   pins its nixpkgs revision in source. `flake.lock` does exist: it carries one
   `github:NixOS/nixpkgs` pin at revision
   `c7def046b9a883d46974757852106483d741586f`, and `NOTICE.md` records it as the
   driver's to write — a lock record, not authored material, and not this fork's.
4. `.fingerprint` is present, at `build.zig.zon:18`:
   `.fingerprint = 0xd671372b083c0ad3`. Lines 17-21 say nothing about why one
   would be absent, because one is not; they carry `.version`, `.fingerprint`,
   `.minimum_zig_version` and the comment that nothing is fetched.
5. The Solaris `-D_REENTRANT` omission in §7 has no observation behind it in
   either direction. It is the first thing to revisit if a Solaris or illumos
   row in the published matrix fails.
6. The typed surface and the runtime table are documented from `zig/root.zig`
   and `runtime/`. If the facade's published names change, README.zig.md and
   README.md's consumption section are what change with them — no other file in
   this set depends on a Zig symbol name.
7. The BSD front end (§7f) is `PENDING-VERIFICATION` end to end. Its three
   causes are `SOURCE-CONFIRMED` line by line, but the failures it repairs were
   reported, not observed here, and the repair is unobserved too. The focused
   gate is one `cross-test` cell per family — a NetBSD cell, `x86-openbsd-none`
   or `arm-openbsd-eabi`, and `mips64-openbsd-none` or `mips64el-openbsd-none` —
   not the whole matrix, and `build_only` coverage is the most a foreign cell
   can be without a runner.
8. Two shapes this wave found but did not act on, both because no cell on them
   was reported failing. `generic-freebsd` repeats the OpenBSD `size_t` pattern
   under `_SIZE_T_DECLARED` (§7f), and `Platform`'s single "every other Unix"
   row gives both BSD families `-ldl` on a shared delivery — whether either
   family still has a separate `libdl` is not established here, and the default
   static delivery never reaches that branch. Either is the first thing to
   revisit if its cell goes red.
9. The canonical devenv gates (§8a) have not been run against the repaired
   `devenv.yaml` and `devenv.nix`, so every statement about a task's new
   behaviour is unobserved. The focused gate is one driver row for lua:
   `info`, `tasks list --json`, `devenv shell -- zig version`, `devenv shell --
   zig env`, `sdk:consumer`, `sdk:provenance`, and `nix build` of `#static` and
   `#shared`. The file-set digest is part of that row rather than a separate
   concern: the tasks now write nothing inside this tree, and the digest is
   what would confirm or refute that. `tools/check-provenance.sh` is the same
   check by another route and is `SOURCE-CONFIRMED` unrun.

## 10. A nested consumer build inherits nothing it was not handed, and the
mode is not a `-D` option

**Condition.** `runConsumer` shells out to a second `zig build` in `consumer/`,
which resolves this package as a path dependency and runs its `build()` again.
Everything the outer graph resolved has to be handed across explicitly, because
that nested graph starts from the build runner's defaults.

**Symptom.** It was not handed the mode. The delivery and dispatch options were
forwarded and `-Dsystem` was not, so `zig build consumer -Dsystem=true` printed
the outer build's `system` line, handed the nested build `-Dlinkage=dynamic`
and no mode, and watched that build resolve **bundled**, compile this tree's
own twenty C units, run the consumer against them and exit 0. Observed by the
driver, not inferred:
`review-contract-probes/evidence/before-20261004T200332Z/index.json`. A green
"consumer package" line was therefore a statement about a configuration nobody
ran, which is the one failure the comment above those arguments already existed
to prevent.

**Fix.** Forward the mode *as this build resolved it*, and forward it as the
build runner's own switch:

```zig
run.addArg(if (library == .system) b.fmt("-fsys={s}", .{lib_name}) else b.fmt("-fno-sys={s}", .{lib_name}));
```

Three source facts make that the spelling rather than a preference.
`b.systemIntegrationOption` reads `graph.system_library_options`, which only
`-fsys=`/`-fno-sys=` populate (`lib/compiler/build_runner.zig:169-174`) and
which is not reachable from the `-D` map at all
(`lib/std/Build.zig:2726-2753`), so a `-Dsystem` would have set the nested
graph's *default* and left the answer to that graph's runner — which is the
same defect one level down. A dependency is built with
`.graph = parent.graph` (`lib/std/Build.zig:352`), so the flag the runner was
given is the same map the dependency's own `systemIntegrationOption(lib_name,
...)` reads (`:116`, `:2731`). And `consumer/build.zig` therefore needs **no**
new option: `cd consumer && zig build run -fsys=lua` reaches the same switch,
which is worth having because that route is the one a caller can state without
this package's help.

Both spellings are forwarded, including `-fno-sys=lua`. That is not a
no-op: it makes the bundled answer authoritative rather than the nested graph's
own default, so a `--system` or `-fsys=lua` on the outer runner cannot make the
consumer prove a mode the outer graph deliberately declined.

**What it costs the gate.** With the mode forwarded, a host without an installed
Lua 5.5 stops and says so. That is the point: the same `before` run records the
mode refusing correctly on this machine — no `lua.h`, no host `-llua`, no
compatible 5.5 headers — when it is entered on the consumer package directly.
Absence of a provider is a boundary and is never to be reported as a pass, nor
allowed to stand in for a source-package result.

**Also in the same nested command line.** The whole line is accounted for, and
each part answers one question. `-Dtarget` from `target.query` and `-Dcpu` from
`target.query.serializeCpuAlloc`, so the architecture, the OS, the ABI and the
CPU model travel as one selection instead of two guesses. `-Doptimize`;
`-Dlinkage` as `deliveredLinkage(target, linkage)` rather than as the option a
caller typed; `-Druntime` written in both values; the mode as
`-fsys=lua`/`-fno-sys=lua`, as above. The five executor switches
`-fdarling`, `-fqemu`, `-frosetta`, `-fwasmtime` and `-fwine`, and
`--libc-runtimes`. `-j8` and `--summary all`: nothing can append a `-j` to a
`Run` step's command, so a nested build left to derive its own width takes
`cpu_count - 1` (`std/Io/Threaded.zig:1639`) and the consumer compiles at a
different width from the build that asked for it, and at a different width
again on whichever machine runs the gate. `--summary all` is for the same
reader, because the nested graph's steps are named after the consumer package.
The local cache as `--cache-dir` with the existing `<outer>/consumer`
subdirectory, since two graphs must not write one manifest directory. The
global cache as `--global-cache-dir`, inherited whole rather than
subdirectoryed, because it is one shared store of packages and hashes, and a
nested build left to resolve its own would fetch again what this graph already
holds.

**And the install prefix the caller named.** The nested graph resolved a prefix
of its own, so anything it installed went to `consumer/zig-out` — a build
artefact inside a source package, which is the one directory this SDK's own
rules say never to write. `runConsumer` hands on `b.install_prefix` when it
differs from `b.build_root.join("zig-out")`, which is the only case in which
the caller named one, and makes a relative value absolute against
`b.graph.cache.cwd` first, because the step's working directory is `consumer/`
and not this build's root. `DESTDIR` is not forwarded; the nested build
inherits the environment this one ran with. The shape is `tzdata/build.zig`'s,
so there is one spelling of this relay in the workspace. The nested command
is `zig build run`, whose `run` step depends on no install step, so this is a
statement about the prefix the nested graph resolves and not about a file
observed under `consumer/`.

**The caller's own arguments cross two hops, and both are in place.** The outer
runner's `b.args` goes behind `--` and becomes the nested graph's own `b.args`,
and `consumer/build.zig` then does `if (b.args) |args| run_exe.addArgs(args)`
on the run step it builds from the executable. `Step.Run` takes its arguments
only from what was added to it (`lib/std/Build/Step/Run.zig:19-20`,
`:523-525`), so without that second line `-- --provider <path>` reached the
nested graph and stopped there, and the consumer program fell through to
`LUA_TEST_PROVIDER` instead. With no arguments both additions are inert, so
`zig build consumer` without arguments is unchanged by either.

The step is still a nested `Run` whose only observable effect is that nested
build, and no `devenv.nix`, `package.nix`, `flake.nix` or `build.zig.zon` line
moved.

**Now observed rather than read.** A nested-delivery proof ran this step in
nine cases for this SDK, all nine as expected: the four linkage and route
combinations twice, once on defaults and once naming `-Dtarget`, `-Dcpu`,
`-Dlinkage`, `-Druntime` and `-fno-sys=lua`, plus one refusal row. Eight exited
0 and each printed the consumer program's own "every answer matched the
documented value"; the ninth exited 1 with `error: NoProviderConfigured`. The
nested lines carried `-Dcpu` beside `-Dtarget` with both equal to what the
caller named, the mode as `-fno-sys=lua`, `-j8`, `--summary all`, `--cache-dir`
under the cache root that case selected, `--global-cache-dir` at the caller's,
and `--prefix` at the prefix that case named. In the four runtime-loaded cases
the provider arrived as `-- --provider <path>`, with every provider variable
absent from the child environment, so both hops of the program's own arguments
are observed rather than inferred. Bounded to those nine cases: `zig build
check`, the published matrix, `-Doptimize=ReleaseSafe`, the Nix and devenv
outputs, the provenance script, and `cd consumer && zig build run` entered
directly are not among them.

**Bound to.** Zig 0.16.0's `b.systemIntegrationOption` and the build runner's
`-fsys=`/`-fno-sys=` parsing, and a package that resolves its mode through that
call rather than through a `b.option` of its own. A future SDK that declares
`-Dsystem` as its own switch and reads it directly still forwards correctly
here — the caller hands over `library`, not an option spelling — but it will
want its own option plumbed through `consumer/build.zig` rather than relying on
the shared `Graph`.

## 11. An error set that mirrors a C status namespace is an upper bound, and
the doc has to say which call reaches which tag

**Condition.** A facade wraps some of a C API and funnels every raw status
through one switch into one Zig error set.

**Symptom.** The set's preamble claimed the vocabulary and the reachability in
one sentence — "one tag per status code `src/lua.h:48-53` and
`src/lauxlib.h:27` define, because each of those is a condition this module
checked" — and the second half was false. `LUA_ERRFILE` has exactly one
producer in the whole tree (`errfile`, `src/lauxlib.c:774-783`), reachable only
from `luaL_loadfilex`, which this facade does not wrap: it is named at
`zig/root.zig:180` only as one of the declarations a caller reaches through
`pub const c`. Read literally, the sentence told a caller that a `switch` over
`Error` had an arm nothing in the module can reach.

**Fix.** Keep the vocabulary, replace the claim. The tag and `statusOk`'s arm
stay — a broader vocabulary is admissible, and deleting a public tag would break
callers for no correctness gained — and the documentation now separates the two
things the old sentence had merged: the set is the C status namespace as a whole,
and *reachability is per method*. `load`/`loadChunk` reach `SyntaxError` and
`MemoryError`; `pcall` and `resume` reach `RuntimeError`, `ErrorInErrorHandler`
and `MemoryError` — the last thrown from anywhere inside the protected call,
which is why no caller can rule it out — and `resume` reports `LUA_YIELD` as
`RuntimeError` itself; `FileError` is reachable from none of them and belongs
to the raw `c.luaL_loadfilex` route. `Status` was already honest about this — it
names codes, not failures, and carries the full auxiliary namespace including
`Status.file` — and is unchanged.

**What was deliberately not done.** No `State.loadFile` was added to give the
tag a producer. That is a feature with its own contract, its own error text and
its own boundary on upstream's `fopen`, and inventing it to justify a tag would
be backwards: the tag exists because the C API defines the status, not because
this module needed a caller for it.

**Bound to.** A facade whose error set is deliberately a mirror of a shared C
status namespace rather than a per-call list. The rule generalises to any such
mapping: the set may be an upper bound, but the documentation must never claim
the upper bound was exercised, and the per-call reachability has to be stated
somewhere the caller can find it. `AGENTS.md` § 4's "cut the taxonomy at what
your own code checked" is not violated by an upper bound; what § 4 forbids, and
what happened here, is *asserting* that every tag in it was checked.

## 12. A consumer step must answer the question its own nested `Run` will ask,
and a negative answer is an install, not a quiet success

**Condition.** A build graph proves a dependent package by shelling out to a
nested `zig build run` in that package's directory, forwarding the configuration
it resolved.

**Symptom.** The outer step asked for `run` unconditionally, so the command was
the same for every target. The nested run step is a plain `addRunArtifact` with
no `allowSkip`, so a foreign target did not skip: `Run`'s foreign arm ended in
`failForeign` and the outer build failed. Read the other way, the step had no way
to express "this host cannot run it", which is the one honest answer available
for a cell with no enabled executor.

**Fix.** Ask the same question `Run` asks, of the resolved target, with
`std.zig.system.getExternalExecutor`, carrying this build's own `b.enable_*`
switches in the `allow_*` options so the decision and the nested run cannot
disagree; answer `run` or `install` from it. `Run`'s own second gate, which fails
a cross GNU libc target given no `--libc-runtimes`, is the one thing `allow_*`
cannot carry and gets its own arm. Everything else on the command line is
untouched, so an install-only cell still resolves the same dependency and still
proves the consumer compiles and links.

**Targets bound.** Zig 0.16.0's `std.zig.system.getExternalExecutor` and the
`allow_*` options beside it. The rule generalises to any relay that runs another
build graph: the sub-command a relay names has to be a function of the resolved
target and the enabled executors, never of the query or of an unexamined
constant. A relayer that cannot ask should not claim the run either way.

**What an install is not.** Not a semantic pass, and not a substitute for one.
The installed binary was never executed, so nothing it would have reported was
observed. That distinction is the reason the negative branch exists rather than
silently reporting build-only coverage as a green consumer.