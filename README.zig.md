# Zig facade API

## Module exports

- Raw calls through `c` preserve the C ABI, variadic calls, and Lua's `longjmp` behavior; runtime dispatch represents variadic tail arguments as one final tuple.
- `runtime_loaded: bool` identifies the selected route at comptime.
- `LoadSource` is `.path` (absolute file path) or `.system` (basename/SONAME). `LoadError` reports validation and loader failures.
- `load(source) LoadError!void` loads an explicit provider. Identical requests are idempotent; another provider returns `ProviderMismatch`. Linked builds panic if `load` is called.
- `loadedSource() ?LoadSource` returns the successful request, borrowed for process lifetime; it returns `null` in linked builds.
- `version_ident() [:0]const u8` returns the NUL-terminated `lua_ident` banner. Runtime mode borrows the provider's storage.
- Constants: `Index`, `version_num`, `version_release_num`, `signature`, `registry_index`, `upvalue_index`, `min_stack`, and `multret`.
- `Library` (base, package, coroutine, debug, io, math, os, string, table, utf8) provides `name`, `opener`, and `mask`.
- `Type`: none, nil, boolean, lightuserdata, number, string, table, function, userdata, thread. `none` means the index does not exist.
- `CompareOp`: eq, lt, le. `ArithOp`: add, sub, mul, mod, pow, div, idiv, band, bor, bxor, shl, shr, unm, bnot. Binary operations use the second stack value as the left operand.
- `Status` maps Lua's ok, yield, runtime, syntax, memory, error-in-error-handler, and file states; `Status.fromCode` returns `null` for unknown codes.
- `Error` contains `SyntaxError`, `MemoryError`, `RuntimeError`, `ErrorInErrorHandler`, `FileError`, and `UnexpectedStatus`. Typed calls do not produce `FileError`; raw `c.luaL_loadfilex` can.
- `CFunction` and `Reg` alias Lua's callback and `luaL_Reg` types.

## `State`

`State` owns one `lua_State`. Do not copy it: a copy duplicates ownership. Calls on each state must be serialized. `deinit()` closes the state, clears its handle, and is safe to repeat; `handle()` panics after close.

- Lifecycle: `init()`, `initWithLibraries()`, `deinit()`, `isOpen()`, `handle()`. Creation returns `InitError = error{OutOfMemory}`.
- Libraries and stack: `openLibraries()`, `openSelectedLibraries(mask, preload)`, `openLibrary(lib)`, `pushGlobals()`, `getTop()`, `setTop(index)`, `discardTop()`, `checkStack(n)`, `absIndex(index)`, `pushValue(index)`, `rotate(index, n)`, `insertTop(index)`, `copy(from, to)`, `move(to, n)`.
- Push: `pushNil`, `pushBoolean`, `pushInteger`, `pushNumber`, `pushBytes`, `pushLightUserdata`, `newUserdata`.
- Read: `typeOf`, `typeNameOf`, `typeNameAt`, `toInteger`, `toNumber`, `toBoolean`, `toBytes`, `rawLength`, `toPointer`, `toCFunction`, `toThread`.
- Tables and values: `newTable`, `getGlobal`, `setGlobal`, `getField`, `setField`, `getIndex`, `setIndex`, `rawGetIndex`, `rawSetIndex`, `rawEqual`, `compare`, `arith`, `concat`, `lengthOf`.
- Compile and call:
  - `load(source, chunk_name, mode) Error!void` accepts byte slices and optional NUL-terminated names. Syntax and memory errors leave the error object on top.
  - `loadChunk(source, chunk_name) Error!void` uses a literal chunk name.
  - `call(nargs, nresults)` is unprotected; Lua errors `longjmp` past Zig defers.
  - `pcall(nargs, nresults, error_func) Error!void` is protected; failure leaves the error object on top.
  - `runChunk(source, chunk_name) Error!void` compiles and calls with no arguments or results. Failure leaves the error object on top.
- Errors: `errorMessage()` borrows the top error bytes until the slot changes or Lua collects them; it returns `null` for values without a string form. `takeError(buffer)` copies and pops on success; `NoErrorMessage` and `ErrorBufferTooSmall` leave the value on the stack. `discardError()` pops it.
- C functions: `pushCClosure`, `register`, `setFunctions`; the `Reg` slice ends with a zeroed sentinel. Longjmp-capable Lua helpers must run under a protected call.
- Collector: `collectGarbage`, `stopGarbageCollector`, `restartGarbageCollector`, `isCollecting`, `garbageKilobytes`, `garbageBytes`, `stepGarbageCollector`, `setGarbageParameter`, `setGenerational`, `setIncremental`. Unavailable GC queries return `null`. `GarbageParameter` is minor_multiplier, major_to_minor, minor_to_major, pause, step_multiplier, or step_size.
- Coroutines: `newThread`, `pushThread`, `statusOf`, `isYieldable`. `newThread` returns a borrowed `ThreadRef` anchored on the parent stack.

### Borrowed values

`pushBytes` and `toBytes` return Lua-owned, length-counted bytes. Their slices expire when the value is collected or its stack slot changes. `toBytes` may convert a number to a string in place. `newUserdata` returns a pointer into Lua-managed storage; collection can invalidate it.

## `ThreadRef`

A non-owning coroutine view; it has no `deinit` and must not outlive its parent `State` or stack anchor. `handle()` returns the raw coroutine. `resume(nargs) Error!usize` returns the result count on success and leaves the error object on the coroutine stack on failure; `LUA_YIELD` maps to `Error.RuntimeError`. `isYieldable()` reports whether it may yield.
