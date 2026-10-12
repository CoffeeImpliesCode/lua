# The Zig interface

How the Lua 5.5.1 SDK is consumed from Zig: the typed surface, the raw
translated C route, the runtime-loading route, the ownership rules and the ABI
a loaded provider has to satisfy.

For provenance, licensing and the build matrix see [`README.md`](README.md);
for the source-level evidence behind the ABI statements see
[`FORK-NOTES.md`](FORK-NOTES.md) §4, §7a and §7e.

The current bookmark targets stock Zig 0.17.0 without changing this interface.
Current 0.17 proof passed all 20 SDK tests, smoke and the separate consumer on
Linux x86_64 in Debug and ReleaseSafe, both linked-static and explicitly
runtime-loaded. See CHANGELOG entry 17. Observations below are historical 0.16
results, not a replay of the cross-platform matrix.

**Status: three configurations observed.** The linked static route, the shared
delivery and the runtime-loaded route have each been built and run on this
host. The full **19-test suite and the smoke pass on the linked route and again
on the runtime-loaded route**, the second time against a real `liblua.so.55.5.1`
this graph built, named explicitly — so the typed stack, retained results, the
error surface, the collector, a raw `lua_pushfstring` tuple call and the
provider's own live `lua_ident` have all been exercised through the dispatch and
not only through a linked archive. Everything [`README.md`](README.md)'s matrix
still lists as `PENDING-VERIFICATION` is unverified here too, and the entries
below describe `zig/root.zig` as it stands rather than a receipt.

## The two routes

```zig
const lua = @import("lua");   // dep.module("lua")
const c = lua.c;              // pub const c = @import("c") in zig/root.zig
```

| Route | What you get | When to use it |
|---|---|---|
| Typed | the documented facade published by `zig/root.zig` | ordinary embedding |
| Raw | `lua.c`, the translated headers, verbatim | an entry point or struct the facade does not wrap |

`c` is re-exported **on the `lua` module**, not published as a module of its own:
registering it separately would hand a dependent the declarations without the
library that satisfies them.

The raw route is the whole header-declared API — `lua_*` from `lua.h`,
`luaL_*` from `lauxlib.h` and `lualib.h`, and the ten `luaopen_*` openers —
with upstream's own types, constants and callbacks, including the variadic entry
points (`lua_pushfstring`, `lua_pushvfstring`, `luaL_error`, `lua_gc`) and the
callback-shaped ones (`lua_pushcfunction`, `lua_CFunction`, `lua_KFunction`,
`lua_Alloc`, `lua_Writer`, `lua_Reader`, `lua_WarnFunction`, `lua_Hook`). Those
are dispatched through real typed function pointers.

### What `c` carries beyond the declarations

**The macro spellings are there.** `translate-c` translates the headers'
function-like macros into wrappers over the entry points they expand to, with
upstream's own operands, so `c.lua_pop(L, n)` is `lua_settop(L, -(n)-1)`
(`src/lua.h:396`), `c.lua_newtable(L)` is `lua_createtable(L, 0, 0)`
(`src/lua.h:398`), `c.lua_tostring(L, i)` is `lua_tolstring(L, i, NULL)`
(`src/lua.h:418`), `c.lua_call(L, n, r)` is `lua_callk(L, n, r, 0, NULL)`
(`src/lua.h:295`), `c.lua_pcall(L, n, r, f)` is
`lua_pcallk(L, n, r, f, 0, NULL)` (`src/lua.h:299`), `c.lua_pushcfunction(L, f)`
is `lua_pushcclosure(L, f, 0)` (`src/lua.h:402`), `c.lua_pushglobaltable(L)` is
the raw `lua_rawgeti` on the registry (`src/lua.h:415-416`) and
`c.luaL_openlibs(L)` is `luaL_openselectedlibs(L, ~0, 0)`
(`src/lualib.h:62`). `lua_tonumber`, `lua_tointeger`, `lua_getextraspace`,
`lua_resetthread`, `lua_register`, `lua_pushliteral`, `lua_isnil`,
`luaL_checkstring`, `luaL_typename`, `luaL_newlib` and `luaL_newlibtable` are
carried the same way, and each of those is what this build's translation
actually emits. Two names that look like macros in older Lua are not:
`lua_absindex` (`src/lua.h:177`) and `lua_xmove` (`src/lua.h:185`) are ordinary
functions in 5.5.1 and are declared as such.

A macro whose body the translation cannot lower arrives as a `pub const` whose
value is `@compileError` — the name exists and cannot be called. Five of them
are Lua's own: `c.luaL_addchar`, `c.luaL_addsize` and `c.luaL_buffsub`
(`src/lauxlib.h:201`, `205`, `207`), plus `c.lua_str2number`
(`src/luaconf.h:457`) and `c.lua_getlocaledecpoint` (`src/luaconf.h:644`) from
`luaconf.h`, which reaches the translation through `lua.h`. A caller that wants
one of those writes the expansion by hand. `State` wraps the same entry points
on the typed side: `discardError` calls `lua_settop` (`src/lua.h:396`), `call`
calls `lua_callk` (`src/lua.h:295`), `register` calls `lua_pushcclosure`
(`src/lua.h:402`), `openLibraries` calls `luaL_openselectedlibs`
(`src/lualib.h:62`).

**A macro is still not a symbol, and that is the whole of the difference.** The
delivered shared object exports no `lua_pop`, no `lua_newtable` and no
`lua_tostring`; what it exports is what those spellings expand to. That is why
the loaded route routes a macro's *target* — the dispatch publishes the wrapper
under the macro's name and resolves the symbol under the expansion's — and why
`tests.zig` and `smoke.zig` call `luaL_len` and `lua_pushfstring` directly
rather than through a macro spelling.

**The variadics arrive as Zig variadics.** `lua_pushfstring`
(`src/lua.h:252`), `luaL_error` (`src/lauxlib.h:76`) and `lua_gc`
(`src/lua.h:360`) are the three real C variadics, and `lua_pushvfstring`
(`src/lua.h:250`) carries its `va_list`. They are the one place the two
configurations do not have the same shape: the linked translation is a C
variadic and takes promoted arguments, while the generated dispatch keeps the
arity and takes the trailing arguments as one final tuple. Every call to one is
a comptime branch on `runtime_loaded`, so a build resolves only the route it
has, and `smoke.zig` and `tests.zig` compile and run both spellings.

**Exported data is live.** `lua_ident` (`src/lua.h:157`) is bound to an
`@extern` of its declared pointer type, so the value is the provider's address
rather than a copy of its bytes. `version_ident()` reads through it in both
configurations, and the runtime-loaded run printed the loaded object's own
`$LuaVersion: Lua 5.5.1 …` string.

In a runtime-loading build `c` is a generated dispatch instead of the
translation step's own output. It publishes the same namespace: every type,
constant and data value is re-exported from the translation rather than
restated, so `State` is the same nominal type either way and nothing here needs
a cast.

## The typed surface

### Loading and lifecycle

* `runtime_loaded: comptime bool` — true in a `-Druntime=true` build.
* `load(LoadSource) LoadError!void`, `loadedSource() ?LoadSource`
* `LoadSource` = `.{ .path = <absolute file> }` or `.{ .system = <basename> }`
* `LoadError`, and `Error` = `error{ SyntaxError, MemoryError, RuntimeError,
  ErrorInErrorHandler, FileError, UnexpectedStatus }`, mapped from `Status`.
  That is the whole C status namespace rather than a per-call list, so read a
  switch with it: no typed call here reaches `FileError`, which only
  `luaL_loadfilex` produces and which a caller gets by calling it through `c`.

### Constants and types

* `version_num` (505), `version_release_num`, `signature`, `registry_index`,
  `upvalue_index(Index)`, `min_stack`, `multret`
* `version_ident() [:0]const u8` — reads `lua_ident` **from the provider's own
  address**, in both the linked and the loaded configuration.
* `Type` (none, nil, boolean, lightuserdata, number, string, table, function,
  userdata, thread), `CompareOp` (eq, lt, le), `ArithOp` (add … bnot),
  `Status` (ok, yield, runtime, syntax, memory, error_in_error, file, plus
  `Status.fromCode`)
* `Library` — base, package, coroutine, debug, io, math, os, string, table,
  utf8, each with `.name()`, `.opener()` and `.mask()`.
* `CFunction = c.lua_CFunction`; `Reg = c.luaL_Reg`; `GarbageParameter`

### `State`

`State` owns exactly one `lua_State`.

* lifetime: `init()`, `initWithLibraries()`, `deinit()`, `isOpen()`, `handle()`
* libraries: `openLibraries()`, `openSelectedLibraries(mask, preload)`,
  `openLibrary(Library)`, `pushGlobals`
* stack shape: `getTop`, `setTop`, `discardTop`, `checkStack`, `absIndex`,
  `pushValue`, `rotate`, `insertTop`, `copy`, `move`
* pushing: `pushNil`, `pushBoolean`, `pushInteger`, `pushNumber`, `pushBytes`,
  `pushLightUserdata`, `newUserdata`
* reading: `typeOf`, `typeNameOf`, `typeNameAt`, `toInteger`, `toNumber`,
  `toBoolean`, `toBytes`, `rawLength`, `toPointer`, `toCFunction`, `toThread`
* tables and globals: `newTable`, `getGlobal`, `setGlobal`, `getField`,
  `setField`, `getIndex`, `setIndex`, `rawGetIndex`, `rawSetIndex`, `rawEqual`,
  `compare`, `arith`, `concat`, `lengthOf`
* evaluation: `load`, `loadChunk`, `call`, `pcall`, `runChunk`
* errors: `errorMessage`, `takeError`, `discardError`
  (`TakeError` = `error{ NoErrorMessage, ErrorBufferTooSmall }`)
* C functions: `pushCClosure`, `register`, `setFunctions`
* collector: `collectGarbage`, `stopGarbageCollector`, `restartGarbageCollector`,
  `isCollecting`, `garbageKilobytes`, `garbageBytes`, `stepGarbageCollector`,
  `setGarbageParameter`, `setGenerational`, `setIncremental`
* threads: `newThread`, `pushThread`, `statusOf`, `isYieldable`

### Running a chunk, and keeping what it returns

`runChunk(source, chunk_name)` is `load` followed by `pcall(0, 0, 0)`: it
compiles the chunk and calls it with **no results retained**, which is
`luaL_dostring`'s own shape (`src/lauxlib.h:152-153`) with a failure returned
instead of turned into a value. It is the right call for a chunk whose work is
its effect, and the wrong one for a chunk that answers a question.

To keep the answers, drive the two steps and say how many you want:

```zig
try state.load("return 6 * 7", "=example", null);
try state.pcall(0, 1, 0);                        // exactly one result
const answer = state.toInteger(-1) orelse return error.NoAnswer;
state.discardTop();
```

`pcall(0, multret, 0)` keeps every result instead of exactly one. The result
count is a promise about the stack: with `nresults` fixed, Lua adjusts the top
to that many values, and with `multret` the top is whatever the chunk returned.
Reading a result is a separate step from calling for it, and
`setTop(before)` is how a caller puts the stack back where it was — that is
what `smoke.zig`'s helpers do around every evaluation.

On failure of either step the error object is left on top and nothing below it
moved, for a compile error and for a runtime error alike; `errorMessage` reads
it, `takeError` takes it, `discardError` drops it.

### `ThreadRef`

A non-owning coroutine view: `handle`, `resume(nargs)`, `isYieldable`, and
**deliberately no `deinit`** — see "Ownership rules".

## Ownership rules a caller must respect

* **One owner, one close.** A state is closed exactly once. `deinit` clears the
  handle, a second `deinit` is a no-op, two states are independent, and globals
  do not survive a close.
* **Protected-call error ownership.** On failure exactly one value replaces the
  chunk's slot and nothing below it moved. Three functions, three different
  ownerships:
  * `errorMessage()` **borrows**. The slice points into Lua's own storage and is
    valid only until that slot is overwritten or collected. Nothing is copied,
    and a value with no string form — `error({})` leaves a table — answers
    null, with `typeOf(-1)` saying what is actually there.
  * `takeError(buffer)` **copies and pops**. On success the message is in the
    caller's buffer and the value is gone from the stack; on
    `error.NoErrorMessage` or `error.ErrorBufferTooSmall` the value is
    deliberately **left where it is**, because a function that has not managed
    to take it must not also destroy it. The returned slice borrows the
    caller's buffer, not Lua's, which is the whole reason to prefer it when
    the text has to outlive the slot.
  * `discardError()` pops and keeps nothing. It is `lua_settop(L, -2)` — the
    expansion of upstream's `lua_pop(L, 1)` (`src/lua.h:396`) — so it removes
    exactly the one value the failed call left.
* **The collector is what ends a borrow.** `collectGarbage` is `lua_gc` with
  `LUA_GCCOLLECT` (`src/lua.h:360`, `:333`) through `callGc`, and any slice
  `errorMessage` or `toBytes` returned is only valid until a collection or an
  overwrite reclaims or replaces it. `stopGarbageCollector` and
  `restartGarbageCollector` bracket a window in which a borrowed slice stays
  put. `garbageKilobytes()` and `garbageBytes()` answer what the collector is
  managing right now and neither collects: the first is `LUA_GCCOUNT`
  (`src/lua.h:334`), read from `lua_gc`'s return value
  (`src/lapi.c:1193-1197`), and the second is the whole number in bytes, which
  upstream splits across `LUA_GCCOUNT` and the `LUA_GCCOUNTB` remainder
  (`src/lua.h:335`, `src/lapi.c:1198-1201`) and `src/lbaselib.c:210-215`
  composes the same way for `collectgarbage("count")`. Both answer null when
  upstream refuses the selector with `-1` (`src/lapi.c:1175-1176`), which
  ordinary Lua code can reach from inside a `__gc` metamethod
  (`src/lgc.c:978-980`); a collector the caller stopped through
  `stopGarbageCollector` is not that case.
* **`isCollecting` follows the same rule.** It is `lua_gc` with
  `LUA_GCISRUNNING` (`src/lua.h:337`; `res = gcrunning(g)`, `src/lapi.c:1221-1222`,
  `src/lgc.h:216`), so it answers upstream's boolean — `true` while the collector
  is running, `false` once `stopGarbageCollector` has set the user's own bit
  (`src/lapi.c:1180-1182`) — and null in the same two windows the counts do.
  Those are a `__gc` metamethod, which upstream runs from inside a cycle
  (`src/lgc.c:968-987`), and the pending finalizers `lua_close` runs through
  `luaC_freeallobjects` (`src/lgc.c:1529-1536`), and in both a collection is in
  fact running — which upstream's own `gcrunning` would have denied, because the
  bit that refusal comes from means stopped to avoid re-entrant steps
  (`src/lgc.h:213-215`). Null here is upstream declining to answer, not a claim
  that nothing is collecting.
* **`toBytes` converts a number in place.** `lua_tolstring` rewrites the slot,
  so `toBytes` on a number leaves a *string* on the stack where a number was.
  That is upstream behaviour (`src/lua.h:418`), not a conversion this SDK
  added, and it is why an error object like `error(42)` reads as `"42"` and
  `typeOf(-1)` afterwards answers `.string`.
* **The `longjmp` boundary.** `lua_error`, `luaL_error`, `luaL_argerror`,
  `luaL_typeerror` and every `luaL_check*` unwind with `longjmp`. They are legal
  only inside a C function that Lua invoked under a protected call, never across
  a Zig `defer`. The facade never calls them itself; a callback you register
  may, and the `pcall` that invoked it is what catches them.
* **Allocator ownership crosses into C.** `luaL_newstate` (`src/lauxlib.c:1197`)
  → `luaL_alloc` (`src/lauxlib.c:1062`) → libc `realloc`/`free`. **No Zig
  allocator is in the path**, so the test framework has no leak oracle for it
  and `deinit` is the whole release. A state is always closed through the route
  that opened it: a linked build never closes a loaded provider, and a loaded
  build never closes a linked archive.
* **`ThreadRef` has no `deinit` on purpose.** `lua_newthread` does not close
  anything: the parent owns the thread, and a second close would run pending
  `__close` metamethods twice. Nothing keeps a thread alive but its parent, so
  `newThread` and `pushThread` hand back a view into the parent's stack rather
  than a second lifetime — a `ThreadRef` must not outlive the `State` it came
  from, and the parent state is still its owner after a failed `resume`.

## The runtime route

`-Druntime=true` builds the same library and routes native calls through one
process-lifetime table instead of linking against it. It is orthogonal to
`-Dlinkage`.

```zig
const lua = @import("lua");

// exactly one of these, explicitly; there is no fallback between them
try lua.load(.{ .path = "/usr/local/lib/liblua.so.55" });  // an absolute path
try lua.load(.{ .system = "liblua.so.55" });                // the soname
```

* `.path` takes an absolute file path. `.system` takes an explicit basename.
  A failed `.path` is not retried as `.system`.
* One table per configured module, for the life of the process. There is no
  library object, no returned API view and no unload; `loadedSource()` reports
  what was selected.
* Calling a native entry point before a successful load panics, in every
  optimization mode including `ReleaseFast` and `ReleaseSmall`.
* A failed attempt publishes nothing; an explicit later `load` is allowed and an
  automatic one never happens.
* A repeated request with the same source is idempotent; a different source
  after a successful load is rejected.
* `LoadSource` and `LoadError` are the types the linked branch also imports from
  the runtime core, so both branches present one signature.
* The route compiles one C file. `runtime/sync.c` supplies the loader's mutex,
  condition variable and thread identity, `runtime/sync.h` declares them, and
  `runtime/library.zig` binds the five `lua_rt_*` symbols by exact name;
  `runtime/graph.zig` passes `RT_SYNC_PREFIX=lua_rt` when it compiles the file
  and `#error`s if that macro is missing. The two spellings of the prefix have
  to agree — this package names the symbols and the build defines the macro —
  and a build where they disagree does not link, which is the whole error
  report. `runtime/loader.zig` itself names no symbol of its own, which is what
  lets two SDKs, or two configurations of one SDK, hold their own loader state
  in one process without sharing any of it; a build that needs a second
  instance gives it its own copy of both files and its own prefix
  (`runtime/graph.zig:112-116`).

### What a loaded provider must match

Resolving the symbols proves the library has those names. It says nothing about
whether the consumer and the provider agree about anything else, so the
boundary is stated in two parts: what `runtime/library.zig` actually checks
before it publishes a table, and what it deliberately does not check.

**Checked before anything is published**, with every check failing to a
`ValidationFailed` the caller sees:

1. **Family.** `lua_version(null)` must answer this header's
   `LUA_VERSION_NUM` — 505. Upstream's own `lua_version` ignores its argument
   (`src/lapi.c:152-155`), so asking it before a state exists is the cheapest
   way to learn which API family the provider implements. A **LuaJIT 2.1
   provider (501) is refused** here, even though most names match.
2. **Live data.** The resolved `lua_ident` address must begin with the bytes
   `src/lapi.c:35-37` writes, `$LuaVersion:`. Exported data arrives as the
   provider's address and never as a copy, so this also proves the data half of
   the table is wired to something real.
3. **Allocator and teardown.** `luaL_newstate` must return a state and
   `lua_close` must release it, through the same table entries — which is why
   no state is ever created by one provider and destroyed by another.
4. **State structure.** A freshly created state must answer `lua_gettop == 0`
   (`src/lstate.c:341-393`), which a provider with a different state structure
   under the same name could not.
5. **Scalar width.** `2^53 + 1` must round-trip through `lua_pushinteger` and
   `lua_tointegerx` as an integer. `lua_Integer` is 64-bit
   (`LUA_INT_LONGLONG`, `src/luaconf.h:136`) and `lua_Number` is `double`
   (`LUA_FLOAT_DOUBLE`, `src/luaconf.h:137`), but `LUA_32BITS`, `LUA_INT_TYPE`
   and `LUA_FLOAT_TYPE` (`src/luaconf.h:143`, `162-182`) change that, and a
   provider built with other values passes different widths through the same
   symbol names.

**Not checked, and therefore obligations on the caller**, not claims of
compatibility:

6. **Layout.** `Instruction`, `lua_Debug` (`src/lua.h:487-507`, which the
   public header exposes by value) and `luaL_Buffer`
   (`src/lauxlib.h:185-195`), whose 1024-byte inline area is
   `LUAL_BUFFERSIZE` (`src/luaconf.h:724`: `16 * sizeof(void*) *
   sizeof(lua_Number)`) and therefore moves with `lua_Number`.
7. **Configuration.** `LUA_USE_APICHECK` (`src/luaconf.h:691`) changes the
   provider's own checking and every `LUA_COMPAT_*` changes library behaviour.
   Equal names do not imply equal behaviour.
8. **Allocator contract.** `lua_Alloc` (`src/lua.h:125`) belongs to whoever
   created the state and is readable through `lua_setallocf`
   (`src/lua.h:379`); a provider and a consumer that disagree about who frees
   what get a crash no symbol check predicts.
9. **Binary chunks.** A precompiled chunk is rejected on load unless
   `LUAC_VERSION`, `LUAC_FORMAT`, the `LUAC_DATA` literal and the sizes of
   `int`, `Instruction`, `lua_Integer` and `lua_Number` all match
   (`src/lundump.c:376-388`). A `luac` artifact is portable to the
   configurations that agree on all of them, and to nothing else.
10. **Callbacks.** `lua_CFunction`, `lua_KFunction`, `lua_Reader`,
    `lua_Writer`, `lua_Alloc`, `lua_WarnFunction` and `lua_Hook` cross the
    boundary in both directions; a callback built against this translation is
    called by the provider's own C with the provider's own calling convention.
11. **Same-provider close.** A state is always closed through the route that
    opened it; a linked route never closes a loaded provider and vice versa.

One thing is deliberately not called at load time: `luaL_checkversion_`
(`src/lauxlib.h:46`), upstream's own version-and-size check. It raises a Lua
error rather than returning one, and a Lua error outside a protected call
reaches the panic handler and aborts the process, which is a failure mode a
loader cannot turn into `ValidationFailed`. The facts it would have checked —
the version number and the scalar widths — are checked above in a form that
returns.

### The exported surface

The three public headers declare 156 functions and one data object: 98
`LUA_API` in `lua.h`, 47 `LUALIB_API` in `lauxlib.h`, and 1 `LUALIB_API` plus
10 `LUAMOD_API` in `lualib.h`. That is the whole contract.

How it is enforced is a namespace, not a list. On ELF a generated version
script exports `lua_*`, `luaL_*` and `luaopen_*` and marks everything else
`local` (`build.zig`'s `setVersionScript`), which covers the 156 functions and
the data object without a hand-maintained catalogue that could omit a
declaration the installed headers carry. On Windows the `LUA_BUILD_AS_DLL`
split gives `LUA_API` its `__declspec(dllexport)` and a generated module
definition file carries the single entry the macro does not reach, `lua_ident
DATA`, because `src/lua.h:157` declares that object without `LUA_API`. There is
no Mach-O equivalent this build can rely on, and `LUA_API` is plain `extern`
outside Windows (`src/luaconf.h:315`), so **on Darwin and on COFF the shared
object also exports Lua's internal symbols**. A caller must therefore treat
"this symbol is present" as evidence of nothing at all on those platforms and
select by name from the list above.

Observed on the delivered ELF object: `nm -D` reports 157 defined dynamic
symbols — 99 `lua_` (the 98 `LUA_API` plus `lua_ident`), 48 `luaL_` (47 in
`lauxlib.h` plus the one `LUALIB_API` in `lualib.h`) and 10 `luaopen_` — and
no `luaS_*`, `luaC_*`, `luaH_*` or any other internal name. A count is not a
proof of correspondence, which is why the ABI obligations above are stated
separately from the export list.

The loaded route routes the same 157 names, and only those:
`provider_optional` and `provider_excluded` in `runtime/graph.zig` are both
empty, because nothing in the three headers sits behind a `LUA_USE_*` or
`LUA_COMPAT_*` macro. A provider that does not export the whole header-declared
API is refused rather than half used. The `stdio` surface the translation also
carries — it reaches it through `src/lauxlib.h:13`'s `<stdio.h>`, for `FILE *`
in `luaL_Stream` — is classified as libc noise in the same file and stays
direct, so a `liblua.so` is never asked for `printf`.

### Exported data

`lua_ident` is the only data symbol a public header declares (`src/lua.h:157`),
defined at `src/lapi.c:35-37` as `"$LuaVersion: " LUA_COPYRIGHT " $"
"$LuaAuthors: " LUA_AUTHORS " $"`. That literal is where the loader's
`$LuaVersion:` prefix check comes from. The translation binds the symbol to an
`@extern` of its declared pointer type, so the value is the provider's address
rather than a copy of the bytes; a loaded table resolves that address and never
copies the string. That is why `version_ident()` reports the provider that was
actually loaded, and why the runtime-loaded run printed that provider's own
banner instead of a constant compiled into the program.

`luai_ctype_` (`lctype.c:28`) and `luaP_opmodes` (`lopcodes.c:22`) are data
objects in the shared object, but they sit behind `LUAI_DDEF` in internal
headers: they are the provider's business, not part of any contract with a
consumer.

## 5.5 here, not 5.1

This SDK pins Lua 5.5.1 and its configuration, and the loader refuses a 5.1
provider. LuaJIT implements the 5.1 API: the version in `lua_ident`, the numeric
types chosen by `luaconf.h`, and the `LUAC_VERSION` check in `lundump.c` all
disagree with this build. [`FORK-NOTES.md`](FORK-NOTES.md) §6 records the pair
as incompatible rather than merely different.

## What the tests cover

`tests.zig` holds independent known answers and behavioural boundaries. There is
no upstream suite to run, for the reason in [`UPSTREAM.md`](UPSTREAM.md). The
suite is **19 tests**, and **all 19 passed** in both configurations that have
been run — 9/9 build steps each, with the smoke matching every expected answer:
the linked static route against `liblua.a`, and the runtime-loaded route against
an installed `liblua.so.55.5.1` named explicitly, where the whole test binary
ran through the dispatch rather than against a linked archive. That second run
is what makes the suite a statement about the loaded route and not only about
the linked one. Each answer below is a value the Lua 5.5 reference manual
states, not a value this package produced.

The receipts are `local://foundation-resumed-lua-gc-finalizer-unreachable.json`
for the linked route and `local://foundation-resumed-lua-gc-loaded-finalizer-unreachable.json`
for the runtime-loaded one, each exit 0 and each carrying `Build Summary: 9/9
steps succeeded; 19/19 tests passed`. An earlier linked run passed 16/16
against the suite as it stood then, before the exact byte count and the two
`isCollecting` refusal tests were added; that figure is history, not a smaller
claim about the suite now.

* **Result counts are explicit, because `runChunk` retains nothing.** The same
  chunk, `return string.format('%d', 1)`, is run twice: through `runChunk` on a
  bare state, where it raises because no library is open, and through
  `load` + `pcall(0, 1, 0)` on an opened one, where the single retained result
  is read back as the string `"1"`. A test that wanted more results would ask
  for `multret`, and `evalString`/`evalInt` in `tests.zig` restore the stack
  with `setTop(before)` after reading.

* **Arithmetic** follows 5.5's integer/float rules: `maxinteger` wraparound, `/`
  always producing a float, floor division on floats, `math.type` subtypes.
* **Strings are byte sequences** — the length of a string with an embedded NUL
  is 3, and a push/`toBytes` round trip keeps NULs and non-UTF-8 bytes.
* **A failed call** leaves exactly one value on the stack and moves nothing
  below it; runtime and syntax statuses are distinguished; the message carries
  the `chunk:1:` prefix.
* **A non-string error object** is reported as such: `error({})` leaves a table
  and `errorMessage()` is null, while `error(42)` is converted in place by
  `lua_tolstring`.
* **`takeError`** leaves the value in place when the buffer is too small or
  there is no string form.
* **A message handler** replaces the error object without changing the depth —
  upstream's `luaD_pcall` old-top behaviour.
* **Library opening** is observable: a bare state has no `string`, an opened one
  has a table; `openLibrary(.math)` alone opens only math; and
  `string.format`, `table.concat` and `utf8.char` return their documented
  answers.
* **A Zig callback** is called by Lua, and a `luaL_error` inside it unwinds
  inside `pcall` rather than through the Zig frame.
* **The collector** — a garbage batch, a table that stays reachable keeps its
  address across a full cycle, stop/collect/restart, and the exact byte count
  below. `isCollecting` is pinned on all four of its answers: running, stopped
  by the caller, and no answer at all from inside a `__gc` metamethod and from
  inside a finalizer that `lua_close` runs. The two refusals are recorded into
  the test's own frame, so "the finalizer never ran" and "it ran and upstream
  refused" stay different facts.
* **The byte count is exact.** A state opened through `c.lua_newstate` with a
  counting `lua_Alloc`, the collector stopped, then a length chosen so the
  total is *not* a whole number of kibibytes: `garbageKilobytes()` equals the
  allocator's live total shifted down by ten, `garbageBytes()` equals it
  exactly, and both agree with Lua's own `collectgarbage("count") * 1024`.
* **Stack positions** — `absIndex`, `checkStack`, `setTop`, `pushValue`
  identity, `__eq` against `rawequal`.
* **Closing is a transition** — handle cleared, second `deinit` a no-op, two
  states independent, globals gone.
* **A thread is a stack value the parent owns** — resume, a failure inside a
  coroutine, yielding twice.
* **The raw route** — a real variadic `lua_pushfstring` (promoted arguments on
  the linked route, one tuple through the runtime-loaded dispatch, the branch
  resolved at comptime), the `luaL_len` the facade does not wrap,
  `lua_pushlstring`/`lua_tolstring` over a byte payload with an embedded NUL,
  and `version_ident()`, whose banner is checked to contain this release's
  `Lua 5.5.1` — a bare "Lua" would pass for every family, this one does not.
* **Numeric boundaries** — an integer with no exact float spelling, a
  non-numeric string that is not a number, `mininteger - 1 == maxinteger`.
* **Value identity** survives push/get, and two tables are at two addresses.
