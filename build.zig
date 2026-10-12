// SPDX-License-Identifier: MIT
// See FORK-LICENSE.md for what that identifier covers.
//
//! Zig 0.17 build for Lua 5.5.1.
//!
//! The library, the auxiliary library and the ten standard libraries are
//! upstream's own C, byte for byte: the 20 units of `CORE_O` and the 12 units
//! of `LIB_O` in `src/Makefile:36-37`, and nothing else. The two programs are
//! upstream's own mains, `src/lua.c` and `src/luac.c` (`src/Makefile:40-45`).
//! Nothing is downloaded, no make, no CMake and no autotools script is executed,
//! and the default mode compiles everything from this repository rather than
//! linking an installed copy.
//!
//! Upstream reference: the official `lua-5.5.1.tar.gz` release,
//! `src/lua.h:20-22` (`LUA_VERSION_MAJOR_N 5`, `LUA_VERSION_MINOR_N 5`,
//! `LUA_VERSION_RELEASE_N 1`) and `README` ("This is Lua 5.5.1, released on
//! 24 Jul 2026"). The release digest belongs in `UPSTREAM.md`, which the
//! fork's provenance owner writes; this script does not restate one.
//!
//! There is no upstream test suite to carry, and no step pretends otherwise:
//! `src/Makefile:69-70` defines `test:` as `./$(LUA_T) -v` and `doc/readme.html`
//! says the same in prose. Lua's conformance library lives in a separate
//! working repository with no digest recorded here, so this graph has no
//! `upstream-test` step and never fetches one.
//!
//! Entry points
//! -----------
//!   zig build           install the library, the five public headers, the
//!                        `lua` and `luac` programs, both man pages, the
//!                        relocatable `lua.pc`, and the licence and provenance
//!                        records; and compile the example
//!   zig build test      run the behavioural tests for the selected target
//!                        (`-Dtarget`; the host when it is absent)
//!   zig build smoke     run the example program
//!   zig build consumer  build the separate `consumer/` package, and run it when
//!                        this host can execute the selected target
//!   zig build check     compile the native library, the facade, the tests,
//!                        the example and both programs for the five buildable
//!                        check targets, running nothing. `wasm32-wasi` is named
//!                        in `refused_check_targets` and stops the build with
//!                        its reason instead of being compiled
//!
//!   cross-test       the same `test` step, for the published 53-platform
//!                   Zig 0.16.0 Tier 1/2 table rather than the host alone.
//!                   `cross-test` discovers `cross-test.profile.sh` from the
//!                   package root, runs `zig build test -Dtarget=TARGET` for
//!                   each of them, and executes the binary where a runner
//!                   exists and records explicit `build_only` coverage where
//!                   one does not. `test` is what the harness reaches for, and
//!                   it builds the same graph and the same test binary for
//!                   whatever `-Dtarget` says: nothing in `build()` narrows the
//!                   graph to the host.
//!
//! Options
//! -------
//!   -Dlinkage=static   a static archive, `liblua.a`. This is the default: it
//!                      is what upstream's own build produces, since
//!                      `src/Makefile:35` names `LUA_A= liblua.a` and no
//!                      platform except `mingw` replaces it.
//!   -Dlinkage=dynamic  a real shared object, `liblua.so.55.5.1` with
//!                      `liblua.so.55` beside it, PIC on every constituent,
//!                      and an export surface of exactly the header-declared
//!                      API. Upstream ships no ELF shared object at all; see
//!                      "Static and shared delivery" below for the one name it
//!                      does state.
//!   -Druntime=true     resolve the native entry points at run time instead of
//!                      linking them. Orthogonal to `-Dlinkage`, which still
//!                      decides which artifact this build delivers and
//!                      installs. Default off; a linked build is unchanged.
//!                      The dispatch itself is `runtime/graph.zig`, which the
//!                      API role owns; `add_graph` names the exact seam.
//!   -Dsystem=true      link an installed `liblua` instead of compiling `src/`.
//!                      Supplies the default of
//!                      `b.systemIntegrationOption("lua", ...)`; a build runner
//!                      that decides the mode itself (`-fsys=lua`) overrides it.
//!   -Dtarget=<triple>  build for one target; `zig build check` then checks
//!                      that target only instead of the whole matrix.
//!   -Doptimize=<mode>  the caller's mode, passed to every graph below.
//!
//! Per-target platform configuration
//! --------------------------------
//! `LUA_USE_*` describes the platform the C is compiled *for*, so it is resolved
//! from the resolved target and put on the compile line of every C
//! translation unit and on the translation itself. `platform` is the one place
//! that mapping exists; the library, the translation, the two programs and the
//! configure line all read it, so a cross build cannot pick up the build
//! host's code path in `loadlib.c`, `liolib.c` or `loslib.c`.
//!
//! The four families, and what each one is drawn from:
//!
//!   * Windows: nothing is defined. `src/luaconf.h:50-52` derives
//!     `LUA_USE_WINDOWS` from `_WIN32` on its own, and that is what brings
//!     `LUA_DL_DLL` (`src/luaconf.h:56`) and the C89 numeric path
//!     (`src/luaconf.h:57`). Upstream's `mingw` target
//!     (`src/Makefile:132-135`) passes only `-DLUA_BUILD_AS_DLL`, so there is
//!     nothing platform-specific to pass here either.
//!   * WASI: no `LUA_USE_*` macro is defined, and neither `LUA_USE_POSIX` nor
//!     `LUA_USE_DLOPEN`. WASI preview 1 has no process spawning and no
//!     `dlopen`, and `src/liolib.c:66-80` and `src/loadlib.c:202-234` both
//!     have answer branches for exactly this case: `io.popen` raises
//!     "'popen' not supported" and every C-module load raises "dynamic
//!     libraries not enabled". That is upstream's own fallback branch, reached
//!     by its own macro logic, not a fork decision. That is what this table
//!     says for WASI; what the build does with it is refuse the target before
//!     any of it reaches a compile line, because `src/loslib.c:97-130` gives
//!     `os.tmpname` no arm this toolchain's WASI libc can compile. See "WASI
//!     and `os.tmpname`" below, and "WASI and `<signal.h>`" for the one thing
//!     WASI does get that no other target gets.
//!   * Darwin: `LUA_USE_POSIX` and `LUA_USE_DLOPEN`, and deliberately *not*
//!     `LUA_USE_MACOSX`. Upstream's `macosx` target
//!     (`src/Makefile:129-130`) passes `-DLUA_USE_MACOSX -lreadline`, and
//!     `src/luaconf.h:79-83` turns that macro into `LUA_USE_READLINE`, which
//!     makes `src/lua.c:462-471` `#include <readline/readline.h>` and the
//!     interpreter stop compiling without readline headers and stop linking
//!     without `-lreadline`. Readline is an interactive convenience, not part
//!     of the language, so this build keeps it where upstream keeps it on
//!     Linux: off the link line and resolved by `dlopen` at run time, with
//!     `fgets` as the fallback (`src/lua.c:485-493`). Darwin also needs no
//!     `-ldl`, because `dlopen` is in its libc (`src/luaconf.h:81` says so).
//!   * macCatalyst: `LUA_USE_IOS`, which is upstream's own configuration macro
//!     for this family and the only one in `src/` that reaches the arm
//!     `src/loslib.c:133-140` writes for it. `src/luaconf.h:86-89` expands
//!     `LUA_USE_IOS` to exactly the `LUA_USE_POSIX` and `LUA_USE_DLOPEN` the
//!     Darwin row above names, so nothing else about a Catalyst build moves,
//!     and - unlike `LUA_USE_MACOSX` - it adds no readline. Upstream passes
//!     that one macro for its own `ios` target (`src/Makefile:120-121`).
//!     "macCatalyst and `os.execute`" below is the whole of why.
//!   * Everything else, Unix: `LUA_USE_POSIX` and `LUA_USE_DLOPEN`, and
//!     `LUA_READLINELIB` so `src/lua.c:508-534` looks for readline at run time
//!     instead of demanding it at build time. Linux gets this through upstream's
//!     own `LUA_USE_LINUX` macro, which `src/luaconf.h:70-76` expands to
//!     exactly these three definitions plus the name `libreadline.so`; using
//!     it directly means the Linux recipe is upstream's rather than a
//!     restatement of it. The other Unixes - the BSDs, Solaris, illumos, AIX -
//!     are `LUA_USE_POSIX` plus `LUA_USE_DLOPEN`, which is upstream's own
//!     `posix` and `solaris` recipes (`src/Makefile:138-142`) with the readline
//!     name the Linux one has.
//!
//! What is never defined: `LUA_USE_C89`, because
//! `src/luaconf.h:92-94` rejects it together with `LUA_USE_POSIX`; `LUA_32BITS`,
//! `LUA_INT_TYPE` and `LUA_FLOAT_TYPE`, because `src/luaconf.h:135-137`
//! already selects `LUA_INT_LONGLONG` and `LUA_FLOAT_DOUBLE` as the defaults and
//! every value here would otherwise have to be restated; `LUA_USE_APICHECK`,
//! which `src/luaconf.h:691` ships commented out; and every `LUA_COMPAT_*`.
//! The numeric ABI this build compiles is therefore upstream's own default:
//! a 64-bit `long long` integer and a `double` number.
//!
//! WASI and `<signal.h>`
//! --------------------
//! One target needs a fact that no `LUA_USE_*` macro can carry, because it is
//! a property of the C library rather than of Lua. Lua's core includes
//! `<signal.h>` unconditionally: `src/lstate.h:129-132` does it to spell
//! `l_signalT` as `sig_atomic_t`, and that header is in `lapi.c`, `lgc.c`,
//! `ldo.c`, `lstate.c` and the rest of `CORE_O`, so it reaches most of the 32
//! units. Both programs reach it too - `src/lua.c:16` includes it outright and
//! `src/luac.c:21-27` pulls in `lstate.h`. This toolchain's
//! `wasm-wasi-musl/signal.h:1-3` is a bare `#error` unless
//! `_WASI_EMULATED_SIGNAL` is defined, so on `wasm32-wasi` those units are not
//! parseable at all without it. `src/Makefile` has no wasm target, so nothing
//! upstream would set it either.
//!
//! What is selected is the toolchain's own emulation, not a substitute this
//! package wrote: the `_WASI_EMULATED_SIGNAL` that same `signal.h` asks for,
//! and the `libwasi-emulated-signal.a` its sysroot ships.
//! `lib/libc/wasi/libc-bottom-half/signal/signal.c:104` is that archive's
//! `raise` and `:121` its `signal`, and `lib/std/zig/target.zig:384` lists
//! `wasi-emulated-signal` among the library names a WASI+musl target is known
//! to have, so the linker resolves the name to that archive with no search path
//! of its own. It delivers a signal synchronously and ends the module through
//! its own `abort`; it is an emulation over what WASI has, not a POSIX signal
//! namespace, and nothing in this build asks it for more than that.
//!
//! `add_c_library` gives the library module both halves. `add_program` gives
//! each program's own module the macro, because `src/lua.c` and `src/luac.c`
//! are compiled there and not in the library's; it does not name the archive a
//! second time, because it does not have to: `Module.linkLibrary` records the
//! library as an `.other_step` (`lib/std/Build/Module.zig:649-659`),
//! `Step.Compile.getCompileDependencies` walks those (`:2083-2108`), and every
//! `system_lib` the walk finds is put on the dependee's own link line
//! (`:1064-1088`). That is how the programs, the facade, `smoke.zig` and
//! `tests.zig` inherit the archive from the one module that names it, and
//! `deliveredLinkage` refusing a shared object on WASI means the walk always
//! chases a static archive rather than skipping one.
//!
//! One thing has to be said about all of that before it is read as a working
//! configuration. `wasm32-wasi` is refused before any of it reaches a compile
//! line: `src/loslib.c:97-130` gives `os.tmpname` two arms and this
//! toolchain's WASI libc has neither, so `refusalFor` stops the build and the
//! target is not in `check_targets`. What is written here records what WASI
//! would be given, and the one thing that is genuinely missing is named in
//! "WASI and `os.tmpname`" below.
//!
//! None of that is surrendered to the refusal, and no upstream byte changes
//! with it. No source is edited, no `LUA_USE_POSIX` is invented - which would
//! put `src/lua.c:47-57` back on `sigaction`, a facility the emulated header
//! does not declare, and would contradict the WASI bullet above - and both
//! statements sit inside the `target.result.os.tag == .wasi` test, so the
//! other five checked targets are given exactly what they had.
//!
//! WASI and `os.tmpname`
//! ----------------------
//! `wasm32-wasi` is refused, and the reason is a property of the C library that
//! no macro on a compile line can carry.
//!
//! `src/loslib.c:97-130` is upstream's own configuration block for `tmpnam` -
//! its own header reads "Configuration for 'tmpnam'" - and it has exactly two
//! arms. `LUA_USE_POSIX` selects `mkstemp` over `<unistd.h>` (`:105-119`);
//! without it the ISO C arm is selected, which is `tmpnam` (`:121-127`).
//! `os.tmpname` at `:172-180` reads both unconditionally, so whichever arm is
//! selected has to work. `src/loslib.c:103` is the outer guard
//! `#if !defined(lua_tmpnam)`, so the whole block is skipped when that one
//! macro is already defined. That is upstream's documented extension point,
//! and it is not a switch: it is the `(buffer, error)` statement itself, the
//! one `:115-119` and `:125` spell out. Setting it means this package writes
//! the C that creates the temporary file, which is a substitute rather than a
//! configuration, so it is not done here. The rest of the block is not a
//! switch either: `LUA_TMPNAMBUFSIZE` (`:109`, `:124`) and
//! `LUA_TMPNAMTEMPLATE` (`:111-113`) only size and seed the two arms above.
//! `src/luaconf.h`, `src/Makefile` and `doc/readme.html` name no `tmpnam`
//! macro anywhere - that block in `loslib.c` is the whole of upstream's
//! configuration for it - and `src/Makefile` has no wasm target, so there is
//! no upstream recipe to copy either.
//!
//! Zig 0.16.0's WASI libc has neither arm. Both names are removed rather than
//! deprecated, each behind the same guard,
//! `#ifdef __wasilibc_unmodified_upstream /* WASI has no temp directories */`:
//! `lib/libc/include/wasm-wasi-musl/stdio.h:148-154` guards `tmpnam`, leaving
//! only a declaration marked
//! `__attribute__((__deprecated__("tmpnam is not defined on WASI")))`, and
//! `stdio.h:64-67` guards `L_tmpnam`, which is therefore not defined at all;
//! `lib/libc/include/wasm-wasi-musl/stdlib.h:118-122` guards `mkstemp`,
//! `mkostemp` and `mkdtemp` the same way. Nothing under `lib/libc/wasi/`
//! defines either name - those two headers are the only places the
//! identifiers occur - so neither arm has an implementation to reach either,
//! and silencing the deprecation would not turn `L_tmpnam` into a definition.
//!
//! In unchanged upstream bytes that is two errors, and they are the two this
//! build reports rather than hides: `src/loslib.c:173` sizes the buffer with
//! the `L_tmpnam` the header does not define, and `:175` calls the `tmpnam` it
//! marks deprecated. (`src/loslib.c:13-17` includes `<errno.h>`, `<locale.h>`,
//! `<stdlib.h>`, `<string.h>` and `<time.h>` and never `<stdio.h>`, so no
//! include chain brings the macro in either.) `LUA_USE_POSIX` is not a way
//! out: it moves the failure to `:117`, where `mkstemp` is equally undeclared,
//! and it puts `src/lua.c:47-57` back on `sigaction`, which this sysroot does
//! not declare either - the reason the bullet above defines no `LUA_USE_POSIX`
//! for this target. Every other facility `loslib.c` uses is present on WASI:
//! `system`, `clock`, `CLOCKS_PER_SEC`, `getenv`, `remove` and `rename` are
//! all declared in that sysroot, which is what makes the `tmpnam` block the
//! whole of the problem in that unit rather than the first of several.
//!
//! So the target is refused rather than patched past, in the shape
//! `lmdb/build.zig:458-536` and `mpfr/build.zig:501-549` use. `src/loslib.c`
//! is not edited, `tmpnam` is not stubbed, and `os` is not dropped to make the
//! rest of the library compile - dropping it would take `os.time`, `os.date`,
//! `os.clock`, `os.getenv`, `os.remove`, `os.rename` and `os.execute` with it,
//! all of them unchanged upstream bytes this package has no licence to remove.
//! The other five checked targets compile the same 32 units they did before,
//! because the whole decision is one `refusalFor(target.result.os.tag)` call.
//!
//! What this is not: it is not a claim that WASI cannot host Lua, only that
//! this pinned `src/loslib.c` does not compile against this toolchain's WASI
//! libc with nothing substituted for it. The cell comes back when upstream's
//! `:103` guard grows an arm for a platform with no temp directory, or when
//! this toolchain's WASI libc stops removing `mkstemp`. Either is upstream's
//! or the toolchain's to make, and this package makes neither.
//!
//! macCatalyst and `os.execute`
//! ----------------------------
//! `src/loslib.c:133-140` has two arms for `l_system`, the macro
//! `os_execute` calls at `:147`. The default is `system(cmd)`; the other is
//! `LUA_USE_IOS`, which is not a replacement for `system` but its absence:
//! `((cmd) == NULL ? 0 : -1)`, with upstream's own comment above it - "Despite
//! claiming to be ISO C, iOS does not implement 'system'". Upstream's `ios`
//! recipe is `SYSCFLAGS="-DLUA_USE_IOS"` (`src/Makefile:121`), so the arm
//! exists, is upstream's, and is what upstream itself selects for this
//! family. `src/luaconf.h:86-89` is the other half of the answer: that macro
//! expands to `LUA_USE_POSIX` and `LUA_USE_DLOPEN` and nothing else, so
//! choosing it costs no readline and no new link-time dependency - the two
//! properties `LUA_USE_MACOSX` would have cost.
//!
//! Nothing else in the tree reacts to it: `LUA_USE_IOS` occurs in exactly
//! three places in the imported source - `src/luaconf.h:86`,
//! `src/Makefile:121` and `src/loslib.c:134` - so on a Catalyst target the
//! whole of what the macro changes is which arm `loslib.c` compiles.
//!
//! What this is not: it is not `posix_spawn`, and it is not a subprocess Lua
//! can run. With that arm `os_execute` hands `luaL_execresult` a `stat` of
//! `-1` and `errno` of `0`, so `src/lauxlib.c:291-305` takes its second
//! branch and `os.execute("x")` answers `nil, "exit", -1`, while
//! `os.execute()` with no argument answers `false` - upstream's own statement
//! that there is no shell. Substituting
//! `posix_spawn` would mean writing the C that runs the child, which is a
//! substitute for a platform decision rather than a configuration of it, and
//! it would contradict `src/loslib.c:136` in upstream's own bytes. The
//! boundary is recorded rather than closed: `os.execute` is the one standard
//! library function this build cannot provide on macCatalyst, and it is
//! unavailable for the reason upstream says it is.
//!
//! The BSD translation front end
//! ----------------------------
//! `zig translate-c` parses C with Aro, and Aro preprocesses as well as
//! parses, so the aggregate header can be read either way round: Aro can do
//! both jobs, or the target's own C preprocessor (`zig cc -E -dD`) can do the
//! first and Aro the second. `aggregateRoute` decides per target and
//! `preprocessedAggregate` is the extra front end. Both routes read this
//! repository's `zig/translate.h`, on the same include path, with the same
//! macros and the same C dialect; only the preprocessor that has to understand
//! the target's C library changes.
//!
//! Every target but NetBSD and OpenBSD keeps the route it had. The two BSD
//! families are not a preference. Three header behaviours in this toolchain's
//! bundled C libraries are ones Aro cannot read, and the two lines
//! `src/lua.h:12-13` and `src/lauxlib.h:12-13` reach all of them: they pull
//! `<stddef.h>`, `<limits.h>`, `<stdint.h>` and `<stdio.h>` into the
//! aggregate, and `stdio.h` is the door all three causes come through.
//!
//! **NetBSD, `_Pragma`.** `generic-netbsd/sys/cdefs.h:431-432` routes
//! `__END_DECLS` through `__END_PUBLIC_DECLS`, which `:411-413` spells as
//! `__END_EXTERN_C` framed by `_Pragma("GCC visibility pop")`, and
//! `generic-netbsd/stdio.h:149` opens a declaration block with `__BEGIN_DECLS`.
//! Every `<stdio.h>` in the aggregate therefore drags two `_Pragma` operator
//! invocations into the translation, and Aro destringizes each into a
//! `#pragma` line it then hands to the parser as C. The whole family shares
//! that one header and that one cause, so the condition is the OS tag and not
//! a list of triples: a list would silently stop covering the next
//! architecture.
//!
//! **OpenBSD, `size_t`.** Every OpenBSD `machine/_types.h` in this toolchain
//! spells `__size_t` as `unsigned long`
//! (`x86-openbsd-none/i386/_types.h:123`, `arm-openbsd-eabi/arm/_types.h:123`,
//! `generic-openbsd/mips64/_types.h:128`), and `generic-openbsd/stdio.h:49-52`
//! declares `typedef __size_t size_t` under `_SIZE_T_DEFINED_`. Aro's own
//! `<stddef.h>` (`lib/compiler/aro/include/stddef.h:8`) is what `src/lua.h:13`
//! reaches first, and it declares `size_t` from `__SIZE_TYPE__` while setting
//! none of the C library's guard macros. So the header's declaration is seen
//! a second time. On the 64-bit OpenBSD targets the two spellings name the
//! same type, and a typedef name may be redeclared to the type it already has,
//! so nothing is reported; on the 32-bit ones - `x86-openbsd-none` and
//! `arm-openbsd-eabi` - the compiler's own `size_t` is not `unsigned long`,
//! and the second declaration is a conflict rather than a repetition.
//!
//! **OpenBSD on MIPS64, the endian predefines.**
//! `generic-openbsd/stdio.h:46` includes `<sys/types.h>`,
//! `generic-openbsd/sys/types.h:45` includes `<sys/endian.h>`,
//! `generic-openbsd/sys/_endian.h:36-40` includes `<machine/endian.h>` under
//! `__FROM_SYS__ENDIAN`, and for this architecture that resolves to
//! `generic-openbsd/mips64/endian.h`. That header derives `_BYTE_ORDER` from
//! `__MIPSEL__` or `__MIPSEB__` (`:32-37`) and stops the translation with an
//! `#error` at `:39-41` when neither is defined. The compiler that compiles
//! the 32 core units predefines exactly one of them for this target; Aro does
//! not, so `<stdio.h>` alone is enough to fail a translation the C archive
//! compiles past.
//!
//! Nothing about the compiled C changes for any of this, and nothing is
//! stubbed, narrowed, renamed or substituted. The extra front end writes the
//! same aggregate header with every `#include` resolved, every conditional
//! settled and - `-dD` - every macro definition kept, for the target the core
//! is being compiled for, on the same `-I src` and the same `-D` list the C
//! units are compiled with. The LP64 non-MIPS OpenBSD cells have no diagnosed
//! cause of their own and take the same front end for uniformity; a per-target
//! list would encode a belief about those cells that nothing here establishes.
//!
//! What is deliberately not on that command line is a blanket predefine. The
//! endian macros above in particular are not added by this package: the
//! preprocessor that expands the aggregate is the one that already emits them
//! for the same target the C core is compiled for, and a `-D` written here
//! would be the package claiming to be the compiler.
//!
//! Static and shared delivery
//! --------------------------
//! `-Dlinkage` selects which artifact this package produces. Nothing about the
//! compiled C changes between the two: the same 32 units, the same platform
//! macros, the same language level, the same numeric configuration.
//!
//! The soname is upstream's. Upstream states no `SOVERSION` anywhere - it has
//! no shared object in its own build - but it names one shared library
//! anywhere: `src/Makefile:132-135` builds `lua55.dll` for `mingw`, and the
//! `55` there is Lua 5.5. That is the only ABI number upstream states, so
//! `abi_version` takes 55 for its major and completes the triple with the
//! release it is built from: `liblua.so.55.5.1` with `liblua.so.55` as the
//! soname, which is the string a consumer's `DT_NEEDED` records and the name a
//! `.system` load has to be given. The minor and patch components distinguish a
//! 5.5.1 build from a 5.5.0 one, which upstream's own `lua55` name cannot.
//!
//! ELF shared libraries export the public `lua_`, `luaL_` and `luaopen_`
//! namespaces. This includes the header-declared `lua_ident` data symbol
//! without a separate function catalogue. Internal `luaS_*`, `luaC_*`,
//! `luaH_*` and related namespaces remain local.
//! Windows uses upstream's `LUA_BUILD_AS_DLL` exports plus a module definition
//! for `lua_ident`, which the public header declares without `LUA_API`.
//!
//! PIC is on the library's own module for a shared build, which is what
//! `Module.pic` reaches the command line as, and the two programs take it from
//! the shared object they link. A static archive needs no relocatability and
//! does not get it, which keeps the default delivery byte-for-byte what
//! upstream produces.
//!
//! On Windows a shared build also splits the DLL macro the way
//! `src/luaconf.h:305-311` splits it: the core units are compiled with
//! `LUA_BUILD_AS_DLL` and `LUA_CORE`, the library units with `LUA_BUILD_AS_DLL`
//! and `LUA_LIB`, the two programs and the translation with `LUA_BUILD_AS_DLL`
//! alone - so the definitions are exported and every consumer's declarations
//! are imported - and the installed `lua.pc` carries `-DLUA_BUILD_AS_DLL` in
//! `Cflags` for a shared install. A static build defines none of the three,
//! which is what leaves `LUA_API` as plain `extern` (`src/luaconf.h:315`).
//!
//! One target boundary belongs here rather than only in the code. WASI has no
//! dynamic linker - `std.Target.DynamicLinker.kind` answers `.none` for it
//! (`lib/std/Target.zig:2345-2402`) - so it cannot carry a shared object at all,
//! and `zig build check -Dlinkage=dynamic` walks a WASI target. That shared
//! configuration is **refused, not substituted**: `deliveredLinkage` stops with
//! a message naming the target and the way out, and a caller who names such a
//! target by hand gets that refusal rather than an archive under a shared
//! object's name, which would be a result the caller did not ask for and
//! cannot tell from support.
//!
//! That refusal was about the delivery alone, and it was the whole of the WASI
//! story for as long as the target compiled. It is not the whole of it now.
//! `src/loslib.c:97-130` gives `os.tmpname` no arm this toolchain's WASI libc
//! can build, so `wasm32-wasi` is refused outright for every linkage and is
//! named in `refused_check_targets` rather than walked by `check`. Because of
//! that there is no row left for the static and shared matrices to disagree
//! about, and both are `check_targets`; what makes WASI unbuildable is now a
//! fact about the C, not about the delivery, and `deliveredLinkage` keeps only
//! the general statement it was always making. See "WASI and `os.tmpname`"
//! for the evidence and for what would bring the cell back.
//!
//! Installed closure
//! -----------------
//! `zig build` installs, in bundled mode:
//!
//!   * the native library, through `b.installArtifact`, and the five public
//!     headers through the `installHeader` calls in `add_c_library`; installing
//!     a header also puts it on the include path of anything that links this
//!     artifact, so an installed C consumer needs nothing from this tree.
//!     The five are upstream's own list (`doc/readme.html`, "include: lua.h
//!     luaconf.h lualib.h lauxlib.h lua.hpp").
//!   * `lib/pkgconfig/lua.pc`, generated by `add_pkg_config`. Lua ships no
//!     `.pc` file at all - `Makefile:96-101` is a `pc` target that only echoes
//!     the values one would contain - so this file is the fork's, and every
//!     field says which upstream line it comes from. `prefix` is
//!     `${pcfiledir}/../..` rather than an absolute path, so the installed file
//!     is correct wherever `--prefix` put it.
//!   * `bin/lua` and `bin/luac`, upstream's two programs
//!     (`src/Makefile:40-45`).
//!   * `share/man/man1/lua.1` and `share/man/man1/luac.1`, upstream's two
//!     manual pages from `doc/`.
//!   * `share/licenses/lua/` with the licence and provenance records, through
//!     `install_licence_records`. A private repository removes no licence
//!     obligation, and a package that ships a binary without them is the
//!     failure this prevents.
//!
//! System mode installs none of that and builds neither program: nothing was
//! compiled from this tree, so there is no artifact to describe, no header this
//! build is the source of, and nothing for the programs to link. `zig build` in
//! that mode says so on stdout.
//!
//! Published routes
//! ----------------
//!   * `dep.module("lua")`: the Zig facade, `zig/root.zig`. This is the one
//!     registered module. It carries `link_libc`, the translated headers as
//!     `c`, and the library behind it.
//!   * `c` on that same module: the translated headers themselves, for a
//!     caller that needs a declaration the facade does not name. It is
//!     deliberately *not* registered as a module of its own: `addModule("c")`
//!     would make `dep.module("c")` resolve and hand a dependent the same
//!     declarations without the library that satisfies them, which is a
//!     reachability a dependent cannot tell from support.
//!   * `dep.artifact("lua")`: the compiled native library, in bundled mode
//!     only, in whichever `-Dlinkage` selected.
//!   * the installed headers, library, programs, man pages and `lua.pc`, for a
//!     C consumer that includes the headers and links the artifact.
//!
//! `README.zig.md` states the same routes for a reader deciding what to import.

const std = @import("std");

/// The runtime-loading build half, owned by the API role.
///
/// `createModule` builds the generated dispatch that replaces
/// `translate.createModule()` under `-Druntime`; it makes the loader-core
/// module itself and re-exports `LoadSource`/`LoadError` from it.
/// `createCoreModule` builds that same core module for the *linked* branch,
/// where there is no dispatch to carry the types and the facade's `rt` import
/// is where they come from.
///
/// The two branches must not both call `createCoreModule`. `LoadSource` and
/// `LoadError` are this SDK's public types, so they have to be the *same*
/// types in one build: a second core instance would be a second, nominally
/// distinct `LoadSource`, and `lua.load(source)` would be handing the facade's
/// type to a function expecting the dispatch's. `add_graph` is the only place
/// that calls either of them.
const graph = @import("runtime/graph.zig");

/// `build.zig.zon` itself. `@import` of the manifest is how a build script
/// reads `.version` without a second copy of it.
const manifest = @import("build.zig.zon");

/// `build.zig.zon .version`, parsed. The parse is the loud part: a manifest
/// whose `.version` is not a semantic version fails to configure here rather
/// than being silently compared as something else.
const manifest_version = std.SemanticVersion.parse(manifest.version) catch
    @panic("build.zig.zon: .version is not a semantic version");

/// Package id, the name a dependent writes in its dependency map, the one
/// registered module and the C artifact. They are one name on purpose:
/// `dep.module("lua")` and `dep.artifact("lua")` describe the same library,
/// and `liblua.a` is what Zig emits for an artifact called `lua` because
/// `std.zig.system` prepends the platform's `lib` prefix.
const lib_name = "lua";

/// The Zig facade. It re-exports the translated module as `c`.
const facade_source = "zig/root.zig";

/// The one header this package translates. It is a fork-authored wrapper whose
/// whole job is to name the three public headers upstream's C consumers
/// include; see the file for why it is a wrapper and not a copy.
const translate_header = "zig/translate.h";

/// Test root, owned by the API role.
const test_source = "tests.zig";

/// The deterministic example program, owned by the API role.
const example_source = "smoke.zig";

/// Where the native source lives. Every internal include in this tree is
/// quoted and relative to this directory, so one include path given to every
/// C compilation and to the translation is what keeps all of it resolvable.
const source_dir = "src";

/// Upstream's version, read out of `src/lua.h:20-22`. It is the version of the
/// C library this package builds, and `build.zig.zon .version` carries the same
/// string; `build` refuses to configure when the two drift apart, so the
/// pkg-config `Version:` field, the shared object's file name and the package
/// manifest cannot describe three different releases.
const upstream_version: std.SemanticVersion = .{ .major = 5, .minor = 5, .patch = 1 };

/// The shared object's ABI version. See "Static and shared delivery" above:
/// the major is upstream's own `lua55.dll` (`src/Makefile:132`), and the minor
/// and patch are the release this build compiles.
const abi_version: std.SemanticVersion = .{ .major = 55, .minor = 5, .patch = 1 };

/// The 20 core translation units of `CORE_O` (`src/Makefile:36`), in upstream's
/// order.
///
/// The list is copied from upstream's, not derived. Nothing may be dropped: the
/// interpreter, the compiler and every C module an embedder loads resolve
/// against this exact set, and `ltable.c`, `lopcodes.c` and `ljumptab.h`
/// together are the interpreter's jump table, which is why `ljumptab.h` is a
/// checked-in source and not something a build step regenerates.
const core_sources = [_][]const u8{
    "src/lapi.c",
    "src/lcode.c",
    "src/lctype.c",
    "src/ldebug.c",
    "src/ldo.c",
    "src/ldump.c",
    "src/lfunc.c",
    "src/lgc.c",
    "src/llex.c",
    "src/lmem.c",
    "src/lobject.c",
    "src/lopcodes.c",
    "src/lparser.c",
    "src/lstate.c",
    "src/lstring.c",
    "src/ltable.c",
    "src/ltm.c",
    "src/lundump.c",
    "src/lvm.c",
    "src/lzio.c",
};

/// The 12 units of `LIB_O` (`src/Makefile:37`): the auxiliary library, the ten
/// standard-library openers and `linit.c`, which is what `luaL_openlibs`
/// actually runs (`src/linit.c:19-31`).
///
/// All ten openers are here and none is optional: `luaopen_base`,
/// `luaopen_coroutine`, `luaopen_table`, `luaopen_io`, `luaopen_os`,
/// `luaopen_string`, `luaopen_math`, `luaopen_debug`, `luaopen_utf8` and
/// `luaopen_package` are declared one apiece in `src/lualib.h:17-55`, and each
/// is defined in exactly the unit this list pairs with it. A facade that
/// promised "standard libraries" and delivered eight would not be the library
/// Lua is.
const lib_sources = [_][]const u8{
    "src/lauxlib.c",
    "src/lbaselib.c",
    "src/lcorolib.c",
    "src/ldblib.c",
    "src/liolib.c",
    "src/lmathlib.c",
    "src/loadlib.c",
    "src/loslib.c",
    "src/lstrlib.c",
    "src/ltablib.c",
    "src/lutf8lib.c",
    "src/linit.c",
};

/// The two program mains, and the names upstream gives their results
/// (`src/Makefile:40-45`).
const Program = struct {
    /// The program.
    name: []const u8,
    /// Its `main`.
    source: []const u8,
};

/// `lua`, the standalone interpreter.
const interpreter: Program = .{ .name = "lua", .source = "src/lua.c" };

/// `luac`, the standalone compiler. Upstream states its linkage requirement in
/// prose (`doc/readme.html`, "Building Lua on other systems"): "In all cases,
/// the compiler luac should be linked statically", and its own `mingw` recipe
/// honours it by building `luac.exe` in a second `$(MAKE)` invocation that does
/// not override `LUA_A` (`src/Makefile:132-135`). `add_tools` does the same
/// thing: `luac` is never linked against the delivered shared object.
const compiler: Program = .{ .name = "luac", .source = "src/luac.c" };

/// The five public headers upstream installs (`doc/readme.html`, "Installing
/// Lua" -> "include: lua.h luaconf.h lualib.h lauxlib.h lua.hpp").
///
/// `lua.hpp` is C++ (`src/lua.hpp:1-9`) and is installed rather than translated:
/// translate-c compiles C, and an installed C++ consumer of this tree needs it
/// exactly as upstream's install provides it.
const public_headers = [_][]const u8{
    "src/lua.h",
    "src/luaconf.h",
    "src/lauxlib.h",
    "src/lualib.h",
    "src/lua.hpp",
};

/// The two manual pages upstream ships in `doc/` and installs under
/// `man/man1` (`doc/readme.html`, "man/man1: lua.1 luac.1").
const man_pages = [_][]const u8{
    "doc/lua.1",
    "doc/luac.1",
};

/// The licence and provenance records `zig build` installs under
/// `share/licenses/lua/`.
///
/// Lua's own grant is not a standalone file: the release tarball has no
/// `LICENSE`, and the MIT text and the Lua.org notice live in `doc/readme.html`
/// and again at the foot of `src/lua.h` (`src/lua.h:523-544`). A package that
/// ships a binary and neither text has removed an obligation a private
/// repository does not remove, so `doc/readme.html` - the file that carries the
/// grant - is installed under the licence directory as well as `src/lua.h`, the
/// header every C consumer includes and therefore already holds. `README` is
/// upstream's own release note, kept byte for byte. The rest are this fork's
/// records.
///
/// `share/licenses/lua` is the location both this build and `package.nix` use,
/// which is what lets the packaging layer's own `install -Dm644` be an
/// idempotent overwrite of these bytes rather than a second copy.
const licence_records = [_][]const u8{
    "src/lua.h",
    "doc/readme.html",
    "README",
    "NOTICE.md",
    "FORK-LICENSE.md",
    "UPSTREAM.md",
    "UPSTREAM.sha256",
    "FORK-NOTES.md",
    "CHANGELOG.md",
};

/// Language level for every C translation unit, pinned.
///
/// Upstream asks for GNU C99 by default: `src/Makefile:9` is
/// `CC= gcc -std=gnu99` for every platform except `c89`, which passes
/// `-std=c89` explicitly (`src/Makefile:107-113`) and is not this build's
/// default because `src/luaconf.h:92-94` refuses `LUA_USE_C89` together with
/// `LUA_USE_POSIX`, i.e. together with every POSIX platform. Pinning the level
/// means it is a fact of this build rather than a fact about the host clang.
const c_flags = [_][]const u8{"-std=gnu99"};

/// Which `liblua` the package links.
const Library = enum {
    /// Compiled from the pinned upstream C in `src/`.
    bundled,
    /// The installed library `systemIntegrationOption("lua")` selected.
    system,
};

/// The cross-compilation matrix `check` walks when no target is named. The
/// order is the one this workspace uses everywhere; nothing is skipped, and
/// nothing here is pre-judged: if a target cannot be satisfied on the machine
/// running the gate, that is for the gate to report.
///
/// `wasm32-wasi` used to be the sixth row and is not any more, because
/// `refusalFor` refuses that operating system outright and no delivery can
/// build it - see "WASI and `os.tmpname`". It is named in
/// `refused_check_targets` rather than dropped, and `checkMatrixPartition`
/// keeps the two lists honest against each other.
const check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
    .{ .cpu_arch = .aarch64, .os_tag = .macos, .abi = .none },
    .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
    .{ .cpu_arch = .riscv64, .os_tag = .linux, .abi = .gnu },
};

/// The rows `check` does not walk because this build refuses them.
///
/// The row is not quietly absent and it is not quietly built: `refusalFor`
/// holds the reason, `refuseTarget` prints it and stops, and
/// `checkMatrixPartition` fails any build of this package if `refusalFor` ever
/// stops refusing it without the row having been moved back and proved.
const refused_check_targets = [_]std.Target.Query{
    .{ .cpu_arch = .wasm32, .os_tag = .wasi },
};

/// The name one program artifact carries in this build graph.
///
/// The published graph installs `bin/lua` and `bin/luac`, the names
/// `src/Makefile:40-43` gives them, and a check graph installs nothing, so its
/// artifacts carry the target triple instead: six targets share one build
/// graph, and six pairs of steps all called "lua" and "luac" make
/// `--summary all` impossible to read.
fn programName(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    base: []const u8,
    public: bool,
) []const u8 {
    if (public) return base;
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    return b.fmt("{s}-{s}-{s}", .{ base, lib_name, triple });
}

/// Both upstream programs, compiled for one target.
const Programs = struct {
    /// The standalone interpreter. It follows the delivered linkage.
    lua: *std.Build.Step.Compile,
    /// The standalone compiler. It is always linked statically; `add_programs`
    /// says why.
    luac: *std.Build.Step.Compile,
};

/// What one target's platform configuration is.
///
/// Resolved from the target being built, never from the build host, and read by
/// the library, the translation, the two programs and the configure line so
/// that one fact is in one place.
const Platform = struct {
    /// The `LUA_USE_*` macros this target's compile line carries.
    macros: []const [2][]const u8,
    /// Whether the target reaches `dlopen` at run time and therefore needs
    /// `loadlib.c`'s first branch (`src/loadlib.c:93-126`) rather than its
    /// fallback (`:202-234`).
    dlopen: bool,
    /// Whether `dlopen` lives in a library this build has to name. It does not
    /// on Darwin, where `src/luaconf.h:81` says so explicitly, and not on
    /// Windows or WASI, which reach `LoadLibrary` or nothing at all.
    separate_dl: bool,
    /// Whether `math.h`'s functions live in a library this build has to name.
    /// Upstream's `src/Makefile:12` always carries `-lm`; on Windows the maths
    /// are in the C runtime instead.
    separate_m: bool,
    /// Whether `__declspec` exists on this target, which is the only place
    /// `src/luaconf.h:305-311`'s `dllexport`/`dllimport` split means anything
    /// and therefore the only place `LUA_BUILD_AS_DLL` belongs - on the library,
    /// on the translation, on the programs and in the installed `lua.pc`.
    dll: bool,

    fn forTarget(target: std.Build.ResolvedTarget) Platform {
        const os_tag = target.result.os.tag;
        if (os_tag == .windows) {
            // Nothing platform-specific: `src/luaconf.h:50-52` derives
            // `LUA_USE_WINDOWS` from `_WIN32` by itself, and that is what
            // brings `LUA_DL_DLL`. See the module comment.
            return .{
                .macros = &.{},
                .dlopen = false,
                .separate_dl = false,
                .separate_m = false,
                .dll = true,
            };
        }
        if (os_tag == .wasi) {
            // Neither POSIX nor dlopen: `src/liolib.c:66-80` and
            // `src/loadlib.c:202-234` both have an answer branch for a target
            // with no process spawning and no dynamic loading, and that is
            // where this lands. See the module comment.
            //
            // `addGraph` refuses this operating system before `forTarget` is
            // reached - `src/loslib.c:97-130` has no arm WASI's libc can
            // build - so the row below is the configuration WASI *would* be
            // given, kept because it is upstream's own answer for the two
            // libraries that do have branches and because it is what has to be
            // right if that refusal ever goes away.
            return .{
                .macros = &.{},
                .dlopen = false,
                .separate_dl = false,
                .separate_m = true,
                .dll = false,
            };
        }
        if (os_tag == .maccatalyst) {
            // Upstream's own configuration macro for this family, and nothing
            // else. `src/luaconf.h:86-89` expands `LUA_USE_IOS` to exactly the
            // `LUA_USE_POSIX` and `LUA_USE_DLOPEN` the Darwin row below
            // spells out, so the platform configuration is the same one; what
            // it adds is `src/loslib.c:133-140`'s other arm for `l_system`.
            //
            // That arm is the whole reason, and it is upstream's: with
            // `LUA_USE_IOS`, `l_system` is `((cmd) == NULL ? 0 : -1)` rather
            // than `system(cmd)`, because this toolchain's Darwin
            // `any-darwin-any/_stdlib.h:205-208` declares `system` with
            // `__IOS_PROHIBITED` - `Availability.h:327` turns that into
            // `__attribute__((availability(ios,unavailable)))`, which covers
            // Catalyst as well - and `src/loslib.c:147` calls it.
            //
            // `LUA_USE_MACOSX` is not an alternative here, and this package
            // does not reach for it: `src/luaconf.h:79-83` turns it into
            // `LUA_USE_READLINE`, which is the link-time `-lreadline` the
            // Darwin row below exists to avoid. `LUA_USE_IOS` names no
            // library, adds no dependency, and is what upstream's own `ios`
            // recipe passes (`src/Makefile:120-121`).
            return .{
                .macros = &.{.{ "LUA_USE_IOS", "1" }},
                .dlopen = true,
                // `dlopen` is in Darwin's libc, Catalyst included: the same
                // `src/luaconf.h:81` this row inherits from the Darwin one.
                .separate_dl = false,
                .separate_m = true,
                .dll = false,
            };
        }
        if (os_tag.isDarwin()) {
            // `LUA_USE_POSIX` + `LUA_USE_DLOPEN`, and not `LUA_USE_MACOSX`.
            // `src/luaconf.h:79-83` would add `LUA_USE_READLINE`, which makes
            // `src/lua.c:462-471` include `<readline/readline.h>` and links
            // `-lreadline`: readline would stop being optional. `LUA_READLINELIB`
            // is left undefined too, so `src/lua.c:508` is not reached at all
            // and the REPL is the `fgets` one - a build that never looks for a
            // library it does not require is a build that cannot fail to link
            // because one is missing.
            return .{
                .macros = &.{
                    .{ "LUA_USE_POSIX", "1" },
                    .{ "LUA_USE_DLOPEN", "1" },
                },
                .dlopen = true,
                // `dlopen` is in Darwin's libc (`src/luaconf.h:81`).
                .separate_dl = false,
                .separate_m = true,
                .dll = false,
            };
        }
        if (os_tag == .linux) {
            // Upstream's own recipe, spelled as upstream spells it:
            // `src/Makefile:123-124` passes `-DLUA_USE_LINUX` and nothing else,
            // and `src/luaconf.h:70-76` expands that macro to `LUA_USE_POSIX`,
            // `LUA_USE_DLOPEN` and `LUA_READLINELIB "libreadline.so"`. Naming
            // the macro rather than the three definitions keeps the Linux
            // configuration the one upstream's `luaconf.h` documents.
            return .{
                .macros = &.{.{ "LUA_USE_LINUX", "1" }},
                .dlopen = true,
                .separate_dl = true,
                .separate_m = true,
                .dll = false,
            };
        }
        // Every other Unix - the BSDs, Solaris, illumos, AIX - gets what
        // upstream's own `posix` and `solaris` recipes give it
        // (`src/Makefile:138-142`): `LUA_USE_POSIX`, plus `LUA_USE_DLOPEN`
        // because that is how `loadlib.c` gets a working C-module loader at
        // all, plus the readline name the Linux branch gets so readline stays
        // a run-time lookup rather than a link-time requirement.
        //
        // Solaris' recipe also passes `-D_REENTRANT`
        // (`src/Makefile:139-141`). It is not passed here: it is a request to
        // the C library for thread-safe `errno` and friends on an old glibc
        // era, it changes no Lua declaration, and adding it for one OS family
        // only would be a portability change with no observed failure behind
        // it. `FORK-NOTES.md` records the omission.
        return .{
            .macros = &.{
                .{ "LUA_USE_POSIX", "1" },
                .{ "LUA_USE_DLOPEN", "1" },
                .{ "LUA_READLINELIB", "libreadline.so" },
            },
            .dlopen = true,
            .separate_dl = true,
            .separate_m = true,
            .dll = false,
        };
    }

    /// One line naming this platform configuration, for the configure-time
    /// output. It reads what `forTarget` resolved rather than deciding anything
    /// of its own, so the printed line cannot disagree with what was compiled.
    ///
    /// A single-macro row is named by its macro rather than by its count: the
    /// `LUA_USE_IOS` row also carries one macro and expands to two definitions,
    /// so a length alone would print Linux's name for it. `std.mem.eql`, not
    /// `==`: `platform.macros[0][0]` is a `[]const u8` and Zig has no `==` for
    /// slices - only for pointers and scalars.
    fn kind(platform: Platform) []const u8 {
        if (platform.macros.len == 0) return "no platform macro; upstream's own default path";
        if (std.mem.eql(u8, platform.macros[0][0], "LUA_USE_LINUX")) return "upstream's LUA_USE_LINUX expansion";
        if (std.mem.eql(u8, platform.macros[0][0], "LUA_USE_IOS")) return "upstream's LUA_USE_IOS expansion";
        if (platform.macros.len == 2) return "LUA_USE_POSIX, LUA_USE_DLOPEN";
        return "LUA_USE_POSIX, LUA_USE_DLOPEN, LUA_READLINELIB";
    }
};

/// `zig translate-c` parses C with Aro, and Aro preprocesses as well as
/// parses, so the aggregate header can be read either way round: Aro can do
/// both jobs, or the target's own C preprocessor can do the first and Aro the
/// second. Which one reads `zig/translate.h` for this target.
const AggregateRoute = enum {
    /// Aro preprocesses `zig/translate.h` for itself and parses what comes out
    /// of it.
    aro,
    /// The target's own C preprocessor expands `zig/translate.h` first, and
    /// Aro parses what that produced.
    preprocessed,
};

/// Chooses the front end that reads `zig/translate.h` for this target.
///
/// ## Aro, on every target but NetBSD and OpenBSD
///
/// glibc, musl, FreeBSD, Darwin and Windows spell `__END_DECLS` as plain
/// tokens, and their `size_t` and endian predefines do not reach the paths
/// this aggregate takes, so Aro reads them without help. Nothing about those
/// targets changes.
///
/// ## The target's own preprocessor on the two BSD families
///
/// NetBSD and OpenBSD each have a header behaviour in this toolchain's bundled
/// C libraries that Aro cannot read, and both are reached by
/// `src/lauxlib.h:13`'s `<stdio.h>`. The causes, the header lines and the
/// targets each one lands on are written out under "The BSD translation front
/// end" in the module comment; the code here names only the two families,
/// because that is the width of the cause: the whole NetBSD family shares one
/// `sys/cdefs.h` spelling, and every OpenBSD `machine/_types.h` in this
/// toolchain spells `__size_t` the same way whatever the architecture. A list
/// of triples would silently stop covering the next architecture, and the
/// OpenBSD cells without a cause of their own are better served by the front
/// end that reads the C library the compiler compiles against than by a route
/// chosen on the strength of a diagnosis nobody made.
fn aggregateRoute(target: std.Build.ResolvedTarget) AggregateRoute {
    return switch (target.result.os.tag) {
        .netbsd, .openbsd => .preprocessed,
        else => .aro,
    };
}

/// `zig/translate.h`, preprocessed for the target being built.
///
/// The extra front end `aggregateRoute` selects for NetBSD and OpenBSD. What
/// this writes is the aggregate header with every `#include` resolved, every
/// conditional settled and every macro definition kept, for the target the C
/// core is being compiled for. Nothing is stubbed, narrowed, renamed or
/// substituted, and no macro is invented for it.
///
/// ## Why this preprocessor may run at all
///
/// It is the compiler running this build script - `b.graph.zig_exe` - so the
/// target, the include path, the widths, the C dialect and the predefines are
/// the ones the 32 core units are compiled with. That is the whole remedy: the
/// three failures are Aro reading a C library the compiler it sits beside
/// reads without difficulty, so the reading is handed to the compiler and the
/// parsing stays with Aro.
///
/// ## Why the flags are the ones the C units get
///
/// `c_flags` is passed as it stands rather than restated, so the aggregate is
/// expanded under the same `-std=gnu99` the core is compiled with; the
/// platform macros and the include path are the same list and the same
/// directory `add_c_library` gives the core. The two lines agreeing is the
/// point, and restating either would be a second place to drift.
///
/// ## Why `-dD`
///
/// Without it the expansion carries no macro definitions and `pub const c`
/// loses them. `luaconf.h` is largely macros, `lualib.h:62`'s
/// `luaL_openlibs` and `lua.h`'s whole `LUA_T*` family are macros, and
/// `zig/root.zig` binds translated constants out of exactly that set, so a
/// dump of used macros only would take it with it. `-dD` keeps the `#define`
/// lines beside the expanded text, so a macro a C caller reads as a macro
/// still reaches Zig as a constant.
///
/// ## Why `-MD`
///
/// `zig/translate.h` reaches every header through `#include`, and a `-I`
/// directory argument contributes nothing but its own resolved path to a run
/// step's manifest: `Run.zig` hashes `resolved_arg`, not the directory's
/// contents. Without a depfile this step's declared inputs would be
/// `zig/translate.h` and a few path strings, and a later revision of
/// `src/lua.h` would be served from the run cache while the translation went
/// on describing the previous one. `-MD` with `-MF`, through
/// `addPrefixedDepFileOutputArg`, hands the discovered headers to the build
/// system as this step's own inputs.
fn preprocessedAggregate(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    include_dir: ?std.Build.LazyPath,
    macros: []const [2][]const u8,
    dll_macro: bool,
) std.Build.LazyPath {
    // `b.graph.zig_exe` is the compiler running this build script, so the
    // preprocessor is the same pinned one the C core is compiled by.
    const run = b.addSystemCommand(&[_][]const u8{ b.graph.zig_exe, "cc", "-E", "-dD" });
    run.setName("preprocess lua translate.h");
    if (!target.query.isNative()) {
        const triple = target.query.zigTriple(b.allocator) catch @panic("lua: unspellable target");
        run.addArg("-target");
        run.addArg(triple);
    }
    // `c_flags` itself, not a copy of it: see the doc comment above.
    run.addArgs(&c_flags);
    if (include_dir) |dir| run.addPrefixedDirectoryArg("-I", dir);
    for (macros) |macro| run.addArg(b.fmt("-D{s}={s}", .{ macro[0], macro[1] }));
    if (dll_macro) run.addArg("-DLUA_BUILD_AS_DLL=1");
    run.addArg("-o");
    const preprocessed = run.addOutputFileArg("lua-translate.c");
    run.addArg("-MD");
    _ = run.addPrefixedDepFileOutputArg("-MF", "lua-translate.d");
    run.addFileArg(b.path(translate_header));
    return preprocessed;
}

/// One target's library and facade.
const Graph = struct {
    /// The compiled C library, or null in system mode, where nothing is
    /// compiled from this tree.
    c_lib: ?*std.Build.Step.Compile,
    /// The facade module, with `c` bound to the translated headers for the
    /// library this graph compiled or selected.
    module: *std.Build.Module,
    /// The platform this graph compiled for, so a caller that adds a program
    /// does not resolve the target a second time and risk disagreeing.
    platform: Platform,
};

/// The name a compiled artifact carries in this build graph.
///
/// The published graph installs `liblua.a`, the name a C consumer's `-llua`
/// needs. A check graph installs nothing, so its artifacts carry the target
/// triple instead: six targets share one build graph, and six steps all called
/// "lua" make `--summary all` impossible to read.
fn artifactName(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    public: bool,
) []const u8 {
    if (public) return lib_name;
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    return b.fmt("{s}-{s}", .{ lib_name, triple });
}

/// Builds one target's library and facade.
///
/// `public` chooses between the package module set, which is what a dependent
/// reaches through `dep.module("lua")`, and a private module. A cross-target
/// check needs the private form: modules are registered by name against the
/// whole build, so registering `lua` once per matrix target would leave only
/// the last of them reachable and silently stop checking the rest. The
/// translated headers are imported rather than registered in both forms; the
/// published routes are named above.
fn addGraph(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
    public: bool,
) Graph {
    // Every route into this file passes through here: `build` for the published
    // graph and for `-Dtarget=`, and `add_target_check` for each matrix cell.
    // `runConsumer` reaches it too, one process later: it shells out to a
    // nested `zig build` in `consumer/` that resolves this package as a
    // dependency, and that nested build runs this `build()`. The refusal is
    // here rather than in `build` so that naming the target by hand and walking
    // the matrix cannot be given two different answers. Nothing has been
    // compiled when this runs - it is a configure-time stop, not a warning hung
    // off a later step.
    if (refusalFor(target.result.os.tag) != null) refuseTarget(b, target);

    const platform = Platform.forTarget(target);
    const c_lib: ?*std.Build.Step.Compile = if (library == .bundled)
        add_c_library(b, target, optimize, linkage, platform, artifactName(b, target, public))
    else
        null;

    // The linkage this target can actually carry, resolved here so the
    // translation and the library cannot disagree about it. `add_c_library`
    // resolves the same value for the same reason.
    const delivered = deliveredLinkage(target, linkage);

    // Everything the translation is given, resolved once, because both routes
    // have to see the same thing: the `.aro` route hands `zig/translate.h` to
    // the translator and this list below, and the `.preprocessed` route hands
    // the translator what `zig cc -E -dD` already expanded with this same list.
    // System mode contributes nothing to either, for the reason the include
    // path comment below gives: there the installed headers are the ones the
    // translation describes.
    const no_macros: []const [2][]const u8 = &.{};
    const translate_macros = if (library == .bundled) platform.macros else no_macros;
    const translate_include: ?std.Build.LazyPath =
        if (library == .bundled) b.path(source_dir) else null;
    const translate_dll = library == .bundled and delivered == .dynamic and platform.dll;

    const translate = b.addTranslateC(.{
        // The two routes differ in exactly one respect. The `.aro` one hands
        // the translator this repository's `zig/translate.h` and lets it
        // preprocess that itself; the `.preprocessed` one hands it what the
        // target's own C preprocessor wrote from the same header, on the same
        // include path, with the same macros and the same C dialect. See
        // `aggregateRoute` for which targets take which.
        .root_source_file = switch (aggregateRoute(target)) {
            .aro => b.path(translate_header),
            .preprocessed => preprocessedAggregate(
                b,
                target,
                translate_include,
                translate_macros,
                translate_dll,
            ),
        },
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (translate_include) |dir| {
        // `zig/translate.h` includes `<lua.h>`, `<lauxlib.h>` and `<lualib.h>`,
        // and this is the only header search path the translation has. Without
        // it the translation would bind to whatever Lua happens to be installed
        // on the build machine and describe that library's declarations rather
        // than the ones this graph compiles (`WISDOM.md` W14). System mode
        // deliberately does not add it: there the same three lines are reached
        // through the installed prefix `lua.pc` names, never through this tree.
        //
        // On the `.preprocessed` route those names were resolved before this
        // step ran; keeping the path here means a future `zig/translate.h` that
        // did reach them is covered on both routes.
        translate.addIncludePath(dir);
    }
    // The same platform macros the C was compiled with, on the translation
    // too. They fix the numeric ABI (`lua_Integer`, `lua_Number`), the export
    // decoration and every `LUA_T*` and `LUA_*LIBK` constant, so a translation
    // that resolved them differently from the compiled C would describe a
    // library this build does not produce.
    for (translate_macros) |macro| translate.defineCMacro(macro[0], macro[1]);
    if (translate_dll) {
        // The declaration half of upstream's DLL split; see
        // "Static and shared delivery" above. `LUA_BUILD_AS_DLL` alone makes
        // `src/luaconf.h:310` decorate every declaration
        // `__declspec(dllimport)`, which is what a consumer of the DLL needs
        // and what `add_c_library`'s `LUA_CORE`/`LUA_LIB` pair turns into
        // `dllexport` for the library's own units. Windows is not a target
        // either BSD front end reaches, so this is a Windows-only answer
        // whichever route the target took.
        translate.defineCMacro("LUA_BUILD_AS_DLL", "1");
    }

    // System mode: the installed `lua.pc` names the include directory this
    // translation needs and the library the module binds, and this one query
    // gives both to both. `createModule` carries the entry onto the `c` module
    // below, so a dependent compiles and links against the same prefix the
    // declarations were read from.
    if (library == .system) {
        translate.linkSystemLibrary(lib_name, .{ .preferred_link_mode = linkage });
    }

    const module = if (public)
        b.addModule(lib_name, .{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        })
    else
        b.createModule(.{
            .root_source_file = b.path(facade_source),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
    // Where the runtime-loading seam is
    // ---------------------------------
    // `runtime/graph.zig`, which the API role owns, exposes
    //
    //     pub fn createModule(
    //         b: *std.Build,
    //         translate: *std.Build.Step.TranslateC,
    //         target: std.Build.ResolvedTarget,
    //         optimize: std.builtin.OptimizeMode,
    //     ) *std.Build.Module
    //
    //     pub fn createCoreModule(
    //         b: *std.Build,
    //         target: std.Build.ResolvedTarget,
    //         optimize: std.builtin.OptimizeMode,
    //     ) *std.Build.Module
    //
    // and `-Druntime` substitutes the first for `translate.createModule()`. It
    // takes the `TranslateC` step this function has already built, so the
    // generated dispatch keeps the exact translated type and constant namespace
    // rather than compiling a second copy of the native extern declarations and
    // casting between two nominally distinct Zig modules: `c.lua_newstate` in
    // the facade and the declaration behind the table are one type.
    //
    // `-Dlinkage` is orthogonal and keeps meaning what it means: it selects
    // which artifact this build *delivers* and installs, never which one the
    // module dispatches through.
    //
    // The `rt` import is for the linked branch only, and the reason is the
    // nominal type rather than the code: `graph.createModule` creates the one
    // core-module instance the generated dispatch uses and re-exports
    // `LoadSource`/`LoadError` from it; a second instance created here for the
    // facade would be a *different* `LoadSource`, and `lua.load(source)` would
    // be handing the facade's type to a function expecting the dispatch's. One
    // instance per build, no more. In a linked build there is no dispatch, so
    // the facade's own `rt` import is where those two public types come from;
    // `zig/root.zig` picks between the two with a comptime branch on
    // `runtime_loaded`, so the module a configuration does not need is never
    // resolved and never compiled.
    //
    // The two programs below are *not* affected by `-Druntime`. They are
    // upstream's own C, compiled from this repository, and they link whatever
    // `-Dlinkage` delivered; the option selects the dispatch of the Zig facade,
    // not how the native interpreter is built.
    if (runtime_loaded) {
        // A loaded provider must arrive through the platform loader, so the
        // link line names nothing. Linking the archive as well would make the
        // linker resolve the same symbols statically and the runtime route
        // would quietly be a linked one. The artifact itself is still built and
        // installed, because delivery and dispatch are separate questions: the
        // whole point of the mode is that a caller may name a provider this
        // tree did not build.
        module.addImport("c", graph.createModule(b, translate, target, optimize));
    } else {
        // The translated headers are imported, never registered.
        // `addModule("c")` would make `dep.module("c")` resolve and hand a
        // dependent the same declarations without the library that satisfies
        // them; `lua.c` on the facade is the supported way in and carries the
        // facade's own linkage.
        module.addImport("c", translate.createModule());
        module.addImport("rt", graph.createCoreModule(b, target, optimize));
        // System mode names the installed library through the translation above,
        // so this module already carries it.
        if (c_lib) |lib| module.linkLibrary(lib);
    }

    // The same include path as the archive's own module, on the module a
    // dependent actually imports, so a dependent that compiles its own C
    // against this package finds the same headers the core was compiled with.
    // System mode does not add it: the installed include directory reaches the
    // dependent through the same `lua.pc` entry.
    if (library == .bundled) module.addIncludePath(b.path(source_dir));

    return .{ .c_lib = c_lib, .module = module, .platform = platform };
}

/// Compiles the C library for one target: `CORE_O` plus `LIB_O`, and nothing
/// else.
///
/// `requested` is the linkage the caller asked for. What it selects is the
/// artifact and nothing else about the compilation. What a shared artifact adds
/// is its own requirements - the soname, PIC, the export surface and the DLL
/// macro split - and `delivered` is what this target can actually carry.
///
/// `name` is the artifact name this graph installs or reports; see
/// `artifactName`.
fn add_c_library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    requested: std.builtin.LinkMode,
    platform: Platform,
    name: []const u8,
) *std.Build.Step.Compile {
    const linkage = deliveredLinkage(target, requested);
    const c_lib = b.addLibrary(.{
        .name = name,
        .linkage = linkage,
        // See "Static and shared delivery" for where `abi_version` comes from.
        // `version` is null for a static archive, which has no soname and no
        // versioned file name.
        .version = if (linkage == .dynamic) abi_version else null,
        .win32_module_definition = if (linkage == .dynamic and target.result.ofmt == .coff)
            b.addWriteFiles().add("lua.def", "EXPORTS\nlua_ident DATA\n")
        else
            null,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            // libc, because every translation unit reaches the C library for
            // its own vocabulary: `<string.h>` for memcpy/memset/strlen across
            // `lobject.c`, `ltable.c` and `lstring.c`, `<math.h>` for the whole
            // of `lmathlib.c`, `<stdio.h>` for `lua_writestring`, `<time.h>`
            // and `<locale.h>` for `loslib.c`.
            .link_libc = true,
            // A shared library is position-independent whether or not this says
            // so; naming it makes the requirement explicit.
            .pic = if (linkage == .dynamic) true else null,
        }),
    });
    const c_mod = c_lib.root_module;

    // For the sources' own quoted includes: every file in `src/` includes its
    // neighbours by bare name.
    c_mod.addIncludePath(b.path(source_dir));

    // The platform configuration for the target being built, not for the host.
    // `addGraph` gives the translation the same list.
    for (platform.macros) |macro| {
        c_mod.addCMacro(macro[0], macro[1]);
    }

    // The DLL macros, on the line that compiles the *definitions*, split exactly
    // as `src/luaconf.h:305-311` splits them. `LUA_BUILD_AS_DLL` marks the
    // declarations as belonging to a shared library and `LUA_CORE`/`LUA_LIB`
    // says this compilation is the one producing it, so `LUA_API` becomes
    // `__declspec(dllexport)`; without either it becomes `__declspec(dllimport)`,
    // which is what `addGraph` gives the translation and what the two programs
    // get. They matter only where `__declspec` exists - everywhere else
    // `LUA_API` is plain `extern` (`src/luaconf.h:315`) - so defining them on
    // an ELF or Darwin build is upstream's own behaviour rather than a
    // portability exception.
    //
    // Both of upstream's own names are defined, and they are defined once for
    // the whole library rather than once per half of it. `src/luaconf.h:302-304`
    // describes the arrangement this build uses - "if you want to create one
    // Windows DLL with the core and the libraries" - and `src/luaconf.h:320-321`
    // says "More often than not the libs go together with the core", which is
    // why the two are alternatives with the same effect (`src/luaconf.h:307`
    // tests `defined(LUA_CORE) || defined(LUA_LIB)`) and why naming one would
    // describe a split this build does not make. A C macro here is a property
    // of the whole module, not of one source file: all 32 units are compiled
    // into one image, so one set of macros is what one image can have.
    const windows_dll = platform.dll and linkage == .dynamic;
    if (windows_dll) {
        c_mod.addCMacro("LUA_BUILD_AS_DLL", "1");
        c_mod.addCMacro("LUA_CORE", "1");
        c_mod.addCMacro("LUA_LIB", "1");
    }

    // WASI signal emulation, and only for WASI.
    //
    // Lua asks for a signal in the compiled C itself, with no macro of its own
    // involved: `src/lstate.h:129-132` includes `<signal.h>` unless
    // `l_signalT` is already defined, and nothing defines it, so every unit of
    // `CORE_O` that reaches that header - `lapi.c`, `lgc.c`, `ldo.c`,
    // `lstate.c` and the rest - includes it. All it wants is `sig_atomic_t`,
    // but asking is enough to stop the compilation. This toolchain's
    // `wasm-wasi-musl/signal.h:1-3` is a bare `#error` unless
    // `_WASI_EMULATED_SIGNAL` is defined, so on `wasm32-wasi` those units are
    // not parseable at all without it. `src/Makefile` has no wasm target, so
    // nothing upstream would set this; the configuration has to come from the
    // target's libc, and it is therefore a property of this build rather than a
    // fact about any Lua macro. See the module comment under "WASI and
    // `<signal.h>`".
    //
    // The provider is the one this toolchain's own WASI sysroot ships:
    // `lib/libc/wasi/libc-bottom-half/signal/signal.c:104` is that archive's
    // `raise` and `:121` its `signal`, and `lib/std/zig/target.zig:384` lists
    // `wasi-emulated-signal` among the library names a WASI+musl target is
    // known to have, so the linker resolves that name to that archive with no
    // search path of its own. It delivers a signal synchronously and ends the
    // module through its own `abort`; it is an emulation over what WASI has,
    // not a POSIX signal namespace.
    //
    // Named once, here, on the module that holds the references. A dependee
    // that links this archive inherits it: `Module.linkLibrary` records the
    // library as an `.other_step` (`lib/std/Build/Module.zig:649-659`),
    // `Step.Compile.getCompileDependencies` walks those
    // (`:2083-2108`), and every `system_lib` the walk finds goes onto the
    // dependee's linker line (`:1064-1088`). `deliveredLinkage` refuses a
    // shared object on WASI, so that walk is always chasing a static archive.
    // The two programs get the macro from `add_program` and the archive from
    // here, by that same route.
    //
    // Nothing is surrendered to get there: no source is omitted, no
    // substitute for `raise` or `signal` is written, and `LUA_USE_POSIX` is
    // not invented - that would put `src/lua.c:47-57` back on `sigaction`,
    // which the emulated header does not declare. Both statements sit inside
    // the `os.tag == .wasi` test, so the other five checked targets are given
    // nothing they did not have before.
    //
    // Unreachable today: `addGraph` refuses `wasi` before this module is
    // configured. It stays because it is the answer for a target whose
    // `src/loslib.c` compiles, which is exactly what `refusalFor` says would
    // bring the cell back, and because deleting it would delete the evidence
    // with it. See "WASI and `os.tmpname`".
    if (target.result.os.tag == .wasi) {
        c_mod.addCMacro("_WASI_EMULATED_SIGNAL", "1");
        c_mod.linkSystemLibrary("wasi-emulated-signal", .{});
    }

    for (core_sources) |source| {
        c_mod.addCSourceFile(.{
            .file = b.path(source),
            .flags = &c_flags,
        });
    }
    for (lib_sources) |source| {
        c_mod.addCSourceFile(.{
            .file = b.path(source),
            .flags = &c_flags,
        });
    }

    // Upstream's own link libraries, and only those: `src/Makefile:12` is
    // `LIBS= -lm $(SYSLIBS) $(MYLIBS)`, so `-lm` is unconditional and `-ldl`
    // arrives only where the platform recipe puts it in `SYSLIBS`
    // (`src/Makefile:123-124`, `:139-141`). `Platform` decides which of the two
    // this target needs, from the target and not from the host.
    //
    // `linkSystemLibrary` takes its `LinkSystemLibraryOptions` explicitly and
    // has no defaults for the call, so the empty options struct is the shape
    // here: `needed`, `weak`, `use_pkg_config`, `preferred_link_mode` and
    // `search_strategy` all keep the values `LinkSystemLibraryOptions` declares
    // (`lib/std/Build/Module.zig:344-361`). For `-lm` and `-ldl` that is what is
    // wanted - a C library name, not a pkg-config package, so `use_pkg_config`
    // has nothing to ask for and the dynamic preference is the right one.
    if (platform.separate_m) c_mod.linkSystemLibrary("m", .{});
    if (linkage == .dynamic and platform.separate_dl and platform.dlopen) {
        c_mod.linkSystemLibrary("dl", .{});
    }

    if (linkage == .dynamic) setVersionScript(b, c_lib, target);

    // Installing the headers also puts them on the include path of anything
    // that links this artifact, so a C consumer needs nothing from this tree to
    // call it. These five are the whole of upstream's installed header list.
    for (public_headers) |header| {
        c_lib.installHeader(b.path(header), std.fs.path.basename(header));
    }

    return c_lib;
}

/// Gives a shared library the export surface upstream's Windows DLL has.
///
/// Export the native public namespaces, including data, without a function
/// catalogue that can omit a declaration from the installed headers.
///
/// Mach-O has no version script that GNU ld or lld reads the same way, so this
/// does nothing for Darwin: a `liblua.55.dylib` from this build exports Lua's
/// internals as well as its API. That is a real difference from the ELF object
/// and it is reported by `build` rather than hidden, because upstream ships no
/// Darwin shared object to match.
fn setVersionScript(
    b: *std.Build,
    c_lib: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    if (target.result.ofmt != .elf) return;

    const files = b.addWriteFiles();
    c_lib.setVersionScript(files.add("lua.map",
        \\LUA_5_5 {
        \\  global:
        \\    lua_*;
        \\    luaL_*;
        \\    luaopen_*;
        \\  local:
        \\    *;
        \\};
        \\
    ));
}

/// Both upstream programs, for one target.
///
/// `lua` follows the delivered linkage, so `-Dlinkage=dynamic` gives a
/// `lua` that loads `liblua.so.55` and a `-Dlinkage=static` gives the one
/// upstream builds: `src/Makefile:60-61` links the interpreter against
/// `$(LUA_A)`, and upstream's `mingw` recipe replaces `LUA_A` with the DLL for
/// `lua.exe` only.
///
/// Two things about that recipe are reproduced rather than invented.
///
/// The static interpreter exports its symbols. `src/Makefile:123-124` links it
/// with `-Wl,-E`, and `doc/readme.html` says why in prose: "we recommend that
/// the Lua library is linked statically into the host program and its symbols
/// exported for dynamic linking; src/Makefile does this for the Lua
/// interpreter". Without it a C module loaded by `require` cannot resolve a
/// single `lua_*` call against the interpreter it is running inside. That is the
/// `-rdynamic` below, on ELF only, which is the object format the flag exists
/// for.
///
/// `luac` is never linked against the shared object. `doc/readme.html` states
/// it ("In all cases, the compiler luac should be linked statically") and
/// `src/Makefile:133-135` implements it with a second `$(MAKE)` that does not
/// override `LUA_A`. So a dynamic build compiles one extra static archive for
/// it, from the same 32 units and the same macros, and installs only the
/// delivered artifact.
fn add_programs(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    platform: Platform,
    c_lib: *std.Build.Step.Compile,
    public: bool,
) Programs {
    const delivered = deliveredLinkage(target, linkage);

    // The archive `luac` links: the delivered one when it is already static,
    // otherwise a second static archive built from the same units and macros.
    //
    // It is not named `luac`: an artifact called `luac` emits `libluac.a`, and
    // the program of that name is in the same graph, so `--summary all` would
    // show two steps called `luac` and say nothing about which is which.
    const luac_lib = if (delivered == .static)
        c_lib
    else
        add_c_library(
            b,
            target,
            optimize,
            .static,
            platform,
            programName(b, target, b.fmt("{s}-lib", .{compiler.name}), public),
        );

    return .{
        .lua = add_program(
            b,
            target,
            optimize,
            delivered,
            platform,
            c_lib,
            interpreter,
            programName(b, target, interpreter.name, public),
            true,
        ),
        .luac = add_program(
            b,
            target,
            optimize,
            .static,
            platform,
            luac_lib,
            compiler,
            programName(b, target, compiler.name, public),
            false,
        ),
    };
}

/// One program: its `main`, its platform macros and the library it links.
fn add_program(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    linkage: std.builtin.LinkMode,
    platform: Platform,
    c_lib: *std.Build.Step.Compile,
    program: Program,
    name: []const u8,
    export_dynamic: bool,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        // libc, and for the reason each program says for itself: `src/lua.c`
        // reaches `<stdio.h>`, `<stdlib.h>`, `<string.h>` and `<signal.h>`, plus
        // `<unistd.h>` under `LUA_USE_POSIX` (`src/lua.c:431`) and `<io.h>` and
        // `<windows.h>` under `_WIN32` (`src/lua.c:436-437`). `src/luac.c` is the
        // one that makes the include path load-bearing rather than tidy: it
        // includes seven of Lua's *internal* headers by bare name - `lapi.h`,
        // `ldebug.h`, `lobject.h`, `lopcodes.h`, `lopnames.h`, `lstate.h` and
        // `lundump.h` (`src/luac.c:21-27`) - because it dumps and reloads
        // bytecode and so needs `lundump`'s format definitions.
        .link_libc = true,
        // No `pic` here. A shared library is position-independent because its
        // own module says so (`add_c_library`), and an executable that links one
        // is not required to be - asking for it would turn every program into a
        // position-independent executable, which is not what upstream's
        // `src/Makefile:60-65` links.
    });
    mod.addIncludePath(b.path(source_dir));
    for (platform.macros) |macro| mod.addCMacro(macro[0], macro[1]);
    // The declaration half of upstream's DLL split for the shared case only; a
    // static build leaves `LUA_API` as plain `extern` (`src/luaconf.h:315`).
    if (platform.dll and linkage == .dynamic) {
        mod.addCMacro("LUA_BUILD_AS_DLL", "1");
    }

    // The interpreter's own main includes `<signal.h>` outright
    // (`src/lua.c:16`), and the compiler's reaches the same include through
    // `src/luac.c:21-27`'s `lstate.h`, so each program's module carries the
    // macro on WASI for exactly the reason `add_c_library` gives the library
    // one. The archive is not named a second time: `mod.linkLibrary(c_lib)`
    // below puts the library module's own `system_lib` entries on this link
    // line, which is where `raise` and `signal` would resolve. See the module
    // comment under "WASI and `<signal.h>`".
    if (target.result.os.tag == .wasi) {
        mod.addCMacro("_WASI_EMULATED_SIGNAL", "1");
    }

    mod.addCSourceFile(.{
        .file = b.path(program.source),
        .flags = &c_flags,
    });
    // The same options `add_c_library` passes and for the same reason: `-lm`
    // and `-ldl` are libc-adjacent library names, not pkg-config packages, so
    // the empty struct keeps `use_pkg_config` and the dynamic preference at
    // their declared values.
    if (platform.separate_m) mod.linkSystemLibrary("m", .{});
    if (platform.dlopen and platform.separate_dl) mod.linkSystemLibrary("dl", .{});
    mod.linkLibrary(c_lib);
    // An installed shared library sits in `lib/` and an installed program in
    // `bin/`, so a program linked against it needs the loader to look beside
    // itself. `addRPathSpecial` is the only way to say a relative `$ORIGIN`
    // rpath: a `LazyPath` here would be resolved against the build cache, which
    // is not where the installed file is.
    if (linkage == .dynamic) {
        if (installedRPath(target)) |rpath| mod.addRPathSpecial(rpath);
    }

    const exe = b.addExecutable(.{ .name = name, .root_module = mod });
    // `-Wl,-E` from upstream's own link line, and only where it is what the
    // interpreter needs it. A statically linked interpreter has to export its
    // own `lua_*` symbols for a C module to resolve against it
    // (`src/Makefile:123-124`); one linked against the shared object already
    // finds them in that object, and upstream's own `mingw` recipe passes no
    // `-Wl,-E` for its DLL case either (`src/Makefile:132-135`). See
    // `add_programs`.
    if (export_dynamic and
        linkage == .static and
        target.result.ofmt == .elf)
    {
        exe.rdynamic = true;
    }
    return exe;
}

/// The rpath an installed program in this package needs, or null where the
/// object format has none.
///
/// `bin/<program>` and `lib/liblua` are siblings under one prefix, so
/// `$ORIGIN/../lib` is the ELF spelling and `@loader_path/../lib` the Mach-O
/// one, which is the form the shared object's own `@rpath/liblua.dylib` install
/// name is resolved against. COFF has neither: `b.installArtifact` puts a DLL
/// in `bin/` beside the program, which is where its loader looks.
fn installedRPath(target: std.Build.ResolvedTarget) ?[]const u8 {
    return switch (target.result.ofmt) {
        .elf => "$ORIGIN/../lib",
        .macho => "@loader_path/../lib",
        else => null,
    };
}

/// Compiles the full graph, the tests, the example and both programs for one
/// matrix target and attaches all of them to `step`.
///
/// Building the test binary and the example is what makes this a check of the
/// facade rather than of an unreferenced archive: Zig analyses a function body
/// only when something calls it, and `tests.zig` and `smoke.zig` call the
/// facade. The full 32-unit C closure and both program mains are compiled by
/// the same graph, so a target that cannot build Lua fails here rather than at
/// the first install. Nothing is run here, so every result this step produces is
/// compile evidence and not a claim that a cross-built binary executed.
fn add_target_check(
    b: *std.Build,
    step: *std.Build.Step,
    query: std.Target.Query,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) void {
    const cross_target = b.resolveTargetQuery(query);
    // The triple names the cross artifacts. Six targets in one build graph
    // otherwise produce six steps called "lua", which makes `--summary all`
    // useless for telling them apart.
    const triple = cross_target.result.zigTriple(b.allocator) catch @panic("unspellable target");

    const cross = addGraph(b, cross_target, optimize, library, linkage, runtime_loaded, false);

    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, cross.module);
    step.dependOn(&b.addTest(.{
        .name = b.fmt("lua-tests-{s}", .{triple}),
        .root_module = test_mod,
    }).step);

    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = cross_target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, cross.module);
    step.dependOn(&b.addExecutable(.{
        .name = b.fmt("lua-smoke-{s}", .{triple}),
        .root_module = example_mod,
    }).step);

    // Both programs are part of the library closure this package delivers, so
    // a target where `lua` or `luac` does not compile is a target this SDK does
    // not support and the matrix says so at build time rather than at install.
    // System mode builds neither: there is no local library for them to link.
    if (cross.c_lib) |c_lib| {
        const programs = add_programs(
            b,
            cross_target,
            optimize,
            linkage,
            cross.platform,
            c_lib,
            false,
        );
        step.dependOn(&programs.lua.step);
        step.dependOn(&programs.luac.step);
    }
}

/// Runs the consumer package as its own `zig build` in `consumer/`.
///
/// The consumer is a separate package on purpose: a manifest dependency here
/// would close a cycle, because its manifest points back at this package by
/// path. Running it as a separate build is what makes the proof real - that a
/// package which only writes `b.dependency("lua", ...)` and `dep.module("lua")`
/// gets a working, correctly linked library, with the archive and libc arriving
/// through the module and nothing else.
///
/// Everything this build resolved travels with it: the target and CPU, the
/// optimize mode, the library mode, the linkage and dispatch shapes, the
/// executor switches, both cache directories, the install prefix, the job
/// width and the summary. An argument left behind would be a proof of a
/// configuration nobody asked for.
///
/// Run when this host can execute the selected target, and install otherwise.
/// `port017_make.zig` asks the external-executor question at make time using
/// the selected executor switches. A target with no executor installs; that is
/// compile evidence and never a semantic pass.
fn runConsumer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    library: Library,
    linkage: std.builtin.LinkMode,
    runtime_loaded: bool,
) *std.Build.Step.Run {
    const triple = target.query.zigTriple(b.allocator) catch @panic("OOM");
    defer b.allocator.free(triple);
    // The same query's other half. The triple above names the architecture,
    // the OS and the ABI; it carries no CPU model and no feature set
    // (`lib/std/Target/Query.zig:421-423`), and `cpu` is a separate option of
    // its own (`lib/std/Build.zig:1479-1483`). `serializeCpu`
    // (`lib/std/Target/Query.zig:530`) writes `native` for a query that named
    // no CPU and `baseline` for a cross query that named none, and
    // `Target.Query.parseCpu` recognises both spellings (`:280-283`), so the
    // nested `standardTargetOptions` resolves this build's selection rather
    // than one of its own. `addArg` copies each argument, so these
    // temporaries can go right after.
    const cpu = target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    defer b.allocator.free(cpu);

    // `b.graph.zig_exe` is the compiler running this build script, so the
    // nested build is the same toolchain rather than whatever is on PATH.
    const run = @import("port017.zig").consumer(b, target);
    run.setName("consumer package");
    run.setCwd(b.path("consumer"));
    run.addArg(b.fmt("-Dtarget={s}", .{triple}));
    // The model and its feature set, for the reason the serialization above
    // gives. Without it the nested build would compile the consumer at a
    // baseline CPU on a host that built the library for something else, and
    // the step would prove a configuration nobody asked for.
    run.addArg(b.fmt("-Dcpu={s}", .{cpu}));
    run.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    // The delivery and dispatch options have to reach the nested build or the
    // consumer would silently check the default graph and say nothing about the
    // configuration that was asked for.
    run.addArg(b.fmt("-Dlinkage={s}", .{@tagName(linkage)}));
    // Both spellings go, not only the true one, so a cell's configuration is
    // stated rather than inferred from a default and the flag cannot be dropped
    // on the way down. `consumer/build.zig:41-48` reads the option and hands it
    // to `b.dependency("lua", ...)`, and that value is what
    // `consumer/src/main.zig:88-89` branches on at comptime.
    run.addArg(b.fmt("-Druntime={s}", .{if (runtime_loaded) "true" else "false"}));
    // The mode *this* build resolved, which is a different question from which
    // option asked for it. `b.systemIntegrationOption` is fed by the build
    // runner's `-fsys=`/`-fno-sys=` flags
    // (`lib/compiler/build_runner.zig:169-174`) and is never an entry in the
    // `-D` map, so forwarding `-Dsystem` would set the nested graph's *default*
    // and leave the answer to that graph's own runner instead of this build's.
    // Both spellings go, so the dependency's own
    // `systemIntegrationOption(lib_name, ...)` resolves the answer this build
    // already reached: a dependency shares its parent's `Graph`
    // (`lib/std/Build.zig:352`) and `system_library_options` is a field of it
    // (`:116`, read at `:2731`).
    //
    // What leaving this out cost is observed, not predicted. An outer
    // `zig build consumer -Dsystem=true` printed its own `system` line, reached
    // the nested build with `-Dlinkage=dynamic` and no mode at all, resolved
    // bundled there from `-Dsystem`'s absent default, compiled this tree's own
    // `src/` - the same twenty units the outer graph had just declined to
    // compile - ran the consumer against them and exited 0.
    // (review-contract-probes/evidence/before-20261004T200332Z/index.json.)
    //
    // The refusal is the other half of this and it is not made quieter: with
    // the mode forwarded, the same command on a host with no installed Lua 5.5
    // stops where the outer build stopped, naming the missing header and the
    // absent `-llua`, instead of proving the bundled graph a second time.
    run.addArg(if (library == .system) b.fmt("-fsys={s}", .{lib_name}) else b.fmt("-fno-sys={s}", .{lib_name}));
    // The nested build carries this workspace's job count and summary in its own
    // command line. Nothing can append a `-j` to a `Run` step's command, so a
    // nested build left to derive its own width takes `cpu_count - 1`
    // (`std/Io/Threaded.zig:1639`) instead, and the consumer this step proves
    // then compiles at a different width from the build that asked for it -
    // and at a different width again on whichever machine runs the gate.
    // `--summary all` is for the same reader: the nested build is a separate
    // graph whose steps are named after the consumer package, and a failure
    // inside it is otherwise one unnamed line.
    run.addArg("-j8");
    run.addArg("--summary");
    run.addArg("all");
    // Cache paths, prefix selection and executor flags are resolved by the maker.
    run.addArg("--");
    run.addPassthruArgs();
    // The nested build is the step's only observable effect.
    run.has_side_effects = true;
    return run;
}


/// Writes `lib/pkgconfig/lua.pc` and installs it.
///
/// Lua ships no `.pc` file: `Makefile:96-101` is a `pc` target that only echoes
/// the values one would contain, and `src/Makefile` has no such target at all.
/// So this file is the fork's, and every field below names the upstream line it
/// comes from:
///
///   * `Name`, `Description`, `Version` - the release, `README`: "This is Lua
///     5.5.1, released on 24 Jul 2026", and the MIT terms `doc/readme.html`
///     states. The conventional `.pc` name for the Lua library is `lua.pc` and
///     its conventional library name is `-llua`, which is what a C consumer
///     writes.
///   * `prefix` is `${pcfiledir}/../..` rather than a substituted absolute
///     path. This graph does not know where `--prefix` will point when it writes
///     the file, and pkg-config resolves `${pcfiledir}` against the `.pc` it
///     found, so the installed file is correct wherever the prefix landed -
///     including a Nix store path that is only known at build time.
///   * `Libs` is `-L"${libdir}" -llua` in both variants, because the library
///     *name* does not change with linkage: a C consumer asks for `-llua` and
///     the linker resolves it to `liblua.a` or, through the `liblua.so`
///     symlink, to the shared object.
///   * `Libs.private` is upstream's own `-lm` (`src/Makefile:12`) and, where
///     the platform configuration selects `LUA_USE_DLOPEN`, upstream's `-ldl`
///     (`src/Makefile:123-124`, `:139-141`). A static consumer needs both to
///     link; a shared consumer already has them inside the object.
///   * `Cflags` is `-I"${includedir}"`, plus `-DLUA_BUILD_AS_DLL` for a shared
///     build. That flag is what makes `src/luaconf.h:310` decorate a consumer's
///     declarations `__declspec(dllimport)` on Windows, which is the half of
///     upstream's DLL split a consumer of the shared object needs.
fn add_pkg_config(b: *std.Build, platform: Platform, linkage: std.builtin.LinkMode) void {
    const files = b.addWriteFiles();
    // The returned step is bound to the install step. `addInstallFileWithDir`
    // *creates* a `Step.InstallFile` and nothing more - dropping the return
    // value builds nothing and installs nothing, and the omission is silent:
    // the step exists, it is simply never in the graph, so an install that was
    // missing its `.pc` file would still report success.
    const install_pc = b.addInstallFileWithDir(
        files.add("lua.pc", b.fmt(
            \\# lua.pc for the Lua 5.5.1 SDK.
            \\#
            \\# Lua's release tarball ships no pkg-config file: Makefile:96-101 is a
            \\# `pc` target that only echoes the values below, and src/Makefile has no
            \\# such target. Every field here is therefore this fork's, and build.zig's
            \\# add_pkg_config names the upstream line each one comes from. `prefix`
            \\# is pcfiledir-relative so the installed file is correct wherever
            \\# --prefix put it.
            \\prefix=${{pcfiledir}}/../..
            \\exec_prefix=${{prefix}}
            \\libdir=${{prefix}}/lib
            \\includedir=${{prefix}}/include
            \\
            \\Name: lua
            \\Description: Lua 5.5.1, the extensible scripting language
            \\Version: {f}
            \\
            \\Requires:
            \\Libs: -L"${{libdir}}" -llua
            \\Libs.private:{s}{s}
            \\Cflags: -I"${{includedir}}"{s}
            \\
        , .{
            upstream_version,
            // Upstream's `-lm`, unconditional (`src/Makefile:12`).
            " -lm",
            // Upstream's `-ldl`, only where the platform recipe puts it in
            // SYSLIBS. `Platform` resolves this per target, and a target with no
            // dlopen - Windows, WASI, and therefore most of a cross matrix -
            // must not name a library the translation never referenced.
            if (platform.dlopen and platform.separate_dl) " -ldl" else "",
            // Upstream's DLL declaration half, for a shared install and only
            // where `__declspec` exists at all: on ELF and Darwin it would be an
            // inert spelling of the default visibility, and putting it in a
            // consumer's `Cflags` would be noise that changes nothing.
            if (linkage == .dynamic and platform.dll) " -DLUA_BUILD_AS_DLL" else "",
        })),
        .prefix,
        "lib/pkgconfig/lua.pc",
    );
    b.getInstallStep().dependOn(&install_pc.step);
}

/// Installs the carried licence texts and provenance records under
/// `share/licenses/lua/`.
///
/// A private repository removes no upstream obligation. Lua's grant is not a
/// standalone file - the tarball has no `LICENSE` - so what installs is the
/// file that carries it: `doc/readme.html` for the MIT text and the Lua.org
/// notice, and `src/lua.h`, which carries the same grant at its foot
/// (`src/lua.h:523-544`) and which every C consumer of the installed headers
/// already holds. `FORK-LICENSE.md` records the owner-authorised grant for this
/// fork's own files; `UPSTREAM.md` and `UPSTREAM.sha256` record the pin; the
/// rest are this fork's records.
fn install_licence_records(b: *std.Build) void {
    for (licence_records) |record| {
        // Bound, for the reason `add_pkg_config` says.
        const install_record = b.addInstallFileWithDir(
            b.path(record),
            .prefix,
            b.fmt("share/licenses/lua/{s}", .{std.fs.path.basename(record)}),
        );
        b.getInstallStep().dependOn(&install_record.step);
    }
}

/// Installs both manual pages under `share/man/man1/`, as upstream's install
/// does (`doc/readme.html`, "man/man1: lua.1 luac.1").
fn install_man_pages(b: *std.Build) void {
    for (man_pages) |page| {
        // Bound, for the reason `add_pkg_config` says.
        const install_page = b.addInstallFileWithDir(
            b.path(page),
            .prefix,
            b.fmt("share/man/man1/{s}", .{std.fs.path.basename(page)}),
        );
        b.getInstallStep().dependOn(&install_page.step);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const system_default = b.option(
        bool,
        "system",
        "Link an installed liblua instead of compiling src/, and translate the " ++
            "installed headers instead of the bundled ones. This supplies the " ++
            "default of systemIntegrationOption(\"lua\"); a build runner that " ++
            "decides the mode itself (-fsys=lua) overrides it.",
    ) orelse false;

    const use_system = b.systemIntegrationOption(lib_name, .{ .default = system_default });
    const library: Library = if (use_system) .system else .bundled;

    const linkage_option = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Deliver the native library as a static archive (the default, and what " ++
            "upstream's own Makefile builds) or as a real shared object with " ++
            "upstream's Lua-5.5 ABI name. This selects the delivery and never " ++
            "the dispatch: the same 32 C units are compiled either way. In " ++
            "system mode this graph builds no artifact at all, so there the " ++
            "option names the kind of installed library to bind to instead, and " ++
            "it defaults to dynamic.",
    );

    // Two defaults, because the two modes had two. The bundled graph compiled a
    // static archive before this option existed and must keep doing so, because
    // `src/Makefile:35` names `LUA_A= liblua.a`; `linkSystemLibrary`'s own
    // default is `.dynamic` (`lib/std/Build/Module.zig:363`), and system mode
    // must keep that too. Deriving one from the other would silently change a
    // consumer's linkage in the mode that option was not written for.
    const linkage: std.builtin.LinkMode = linkage_option orelse
        (if (library == .system) .dynamic else .static);

    // `-Druntime` selects the *dispatch*, and it is orthogonal to `-Dlinkage`:
    // the option says which artifact this build delivers and installs, this one
    // says whether the Zig facade calls it through a link line or through a
    // table an explicit `load` fills. Under `-Druntime` nothing is linked into
    // the facade module at all, so a caller may name a provider this tree did
    // not build - and the artifact is still built and installed, so a caller may
    // equally name the one it did.
    const runtime_loaded = b.option(
        bool,
        "runtime",
        "Resolve the native entry points at run time instead of linking them. " ++
            "The facade keeps the same translated headers and the same public " ++
            "types; each selected native function becomes a dispatch through " ++
            "one process-lifetime table that an explicit load(source) fills, " ++
            "and the module links no archive. Independent of -Dlinkage, which " ++
            "still decides which artifact this build delivers and installs. " ++
            "Default off, and a linked build is unchanged in every respect.",
    ) orelse false;

    // `build.zig.zon .version` and the version this build stamps into `lua.pc`,
    // names into the shared object's file name and documents in four other
    // places are one fact. `std.SemanticVersion.parse` fails loudly rather than
    // wrapping a non-version, and the comparison catches a manifest edited
    // without the source it describes.
    if (manifest_version.order(upstream_version) != .eq) {
        @panic("build.zig.zon .version no longer matches the version read out " ++
            "of src/lua.h; see UPSTREAM.md");
    }

    // Two lists, one decision function, checked before any graph is
    // configured: a row cannot be quietly wrong in either direction, and a
    // caller finds out from `zig build` rather than from a gate.
    checkMatrixPartition(b);

    const published = addGraph(b, target, optimize, library, linkage, runtime_loaded, true);

    // In system mode there is no artifact from this tree to install and no
    // program to build, and installing an empty stand-in would be a claim this
    // build cannot make.
    if (published.c_lib) |c_lib| {
        b.installArtifact(c_lib);
        add_pkg_config(b, published.platform, deliveredLinkage(target, linkage));
        install_licence_records(b);
        install_man_pages(b);

        // Both programs. The interpreter follows the delivered linkage; the
        // compiler is always static, which `add_programs` says why.
        const programs = add_programs(
            b,
            target,
            optimize,
            linkage,
            published.platform,
            c_lib,
            true,
        );
        b.installArtifact(programs.lua);
        b.installArtifact(programs.luac);
    }

    // `zig build` also compiles the example. The example is the cheapest thing
    // that proves the facade, the translated headers and the C archive agree on
    // types, symbols and link-time dependencies. It is compiled, not installed:
    // it is a proof, not a deliverable.
    const example_mod = b.createModule(.{
        .root_source_file = b.path(example_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    example_mod.addImport(lib_name, published.module);
    const example = b.addExecutable(.{
        .name = "lua-smoke",
        .root_module = example_mod,
    });
    b.getInstallStep().dependOn(&example.step);

    // A run artifact already depends on building the executable, which depends
    // on compiling the C and linking the facade. `zig build smoke` deliberately
    // does not depend on the install step: installing is `zig build`'s job and
    // conflating the two would make a smoke run depend on the install layout.
    const run_example = b.addRunArtifact(example);
    run_example.has_side_effects = true;
    run_example.addPassthruArgs();
    b.step("smoke", "Run the deterministic example program").dependOn(&run_example.step);

    // The test root is `tests.zig`, which names the test blocks; a root that
    // only re-exported them would discover no tests and still exit zero.
    // `addRunArtifact` is used rather than a plain compile so that this is a
    // real runnable test step for whatever `-Dtarget` names: a foreign target is
    // left to whichever executor the cross-test harness detects, and this build
    // does not decide that.
    const test_mod = b.createModule(.{
        .root_source_file = b.path(test_source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport(lib_name, published.module);
    const unit_tests = b.addTest(.{
        .name = "lua-tests",
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    run_tests.has_side_effects = true;
    b.step("test", "Run the behavioural tests").dependOn(&run_tests.step);

    // The separate consumer package, built as its own `zig build`. It runs when
    // this host can execute the selected target and installs when it cannot,
    // which is `hostCanExecute` rather than a query predicate: a cross-compiled
    // consumer binary cannot run here, and a native one can run under an enabled
    // executor. An install is compile evidence and nothing more.
    //
    // `library` is the mode `build` resolved, not the option a caller typed, so
    // the nested build is asked for the configuration this build is actually
    // in. That is the whole correction `runConsumer`'s own comment asks for.
    b.step("consumer", "Build or run the consumer/ package for the selected target")
        .dependOn(&runConsumer(b, target, optimize, library, deliveredLinkage(target, linkage), runtime_loaded).step);

    // The cross target gate. Compiling the tests, the example, both programs and
    // the whole C closure for each target is what makes this a check of the
    // facade rather than of an unreferenced archive. Nothing runs here.
    const check_step = b.step(
        "check",
        "Compile the native library, the facade, the tests, the example and " ++
            "both programs for the five buildable check targets without running " ++
            "any of them",
    );
    if (!target.query.isNative()) {
        add_target_check(b, check_step, target.query, optimize, library, linkage, runtime_loaded);
    } else {
        // One matrix, whatever the delivery. `-Dlinkage=dynamic` used to walk a
        // shorter list that dropped every target whose OS has no dynamic linker,
        // and `wasm32-wasi` was the only row that difference removed. That row
        // is refused outright now - `refusalFor`, and `refused_check_targets` -
        // so there is nothing left for the two deliveries to disagree about,
        // and `-Dlinkage` selects the artifact rather than the set of targets.
        // A caller who names a target with no dynamic linker by hand is still
        // refused, by `deliveredLinkage`.
        //
        // `[0..]`, not `.*`: `.*` is for dereferencing a single optional or
        // error-union payload, so the pointer-to-array has to become a slice
        // before it can be iterated.
        for (check_targets[0..]) |query| {
            add_target_check(b, check_step, query, optimize, library, linkage, runtime_loaded);
        }
    }

    // Which platform macros this configuration compiled, and which artifact it
    // hands back, are facts worth reading out of the build rather than
    // inferring from a cache directory. These are configure-time lines, not
    // gate results: nothing has been compiled when they print.
    if (published.c_lib != null) {
        std.debug.print("lua: {d} core + {d} library units, {s}, C99 (gnu99), 64-bit lua_Integer and double lua_Number\n", .{
            core_sources.len,
            lib_sources.len,
            published.platform.kind(),
        });
        std.debug.print("lua: {s}\n", .{switch (deliveredLinkage(target, linkage)) {
            .static => "static archive liblua.a (default, and what upstream builds)",
            .dynamic => b.fmt("shared object liblua.so.{d}.{d}.{d}, soname liblua.so.{d}", .{
                abi_version.major,
                abi_version.minor,
                abi_version.patch,
                abi_version.major,
            }),
        }});
        if (runtime_loaded) {
            // Dispatch is a separate fact from delivery, and a runtime-loaded
            // build links nothing into the facade module: the caller names a
            // provider with an explicit `load(source)` and the symbols arrive
            // through the platform loader. Printing it here is what keeps "the
            // library is still built and installed" from reading as "the module
            // links it".
            std.debug.print(
                "lua: runtime-loaded dispatch (-Druntime=true); the facade module " ++
                    "links no archive and a provider is named by an explicit " ++
                    "load(source)\n",
                .{},
            );
        }
        // `-Dlinkage=dynamic` used to print, here, every `check_targets` row its
        // OS could not carry a shared object on. That walk is gone because it
        // can no longer find anything: the one row it reported, `wasm32-wasi`,
        // is in `refused_check_targets` and never reaches this configure line.
        // What makes a target unbuildable is `refusalFor`; what makes a
        // *delivery* impossible is `deliveredLinkage`, which refuses it where it
        // is first asked for rather than as a printed note here.
        if (deliveredLinkage(target, linkage) == .dynamic and
            target.result.ofmt != .elf)
        {
            // See `setVersionScript`. A Mach-O or COFF shared object gets
            // upstream's `__declspec` split only where `__declspec` exists, so
            // a Darwin shared object from this build exports Lua's internal
            // symbols as well as its API. Said here rather than left to be
            // discovered by `nm -D`.
            std.debug.print(
                "lua: {s} has no version-script mechanism here, so the shared " ++
                    "object exports Lua's internal symbols as well as its API\n",
                .{@tagName(target.result.ofmt)},
            );
        }
    } else {
        std.debug.print("lua: system liblua (-llua) and the installed headers; this package installs nothing and builds neither program\n", .{});
        if (runtime_loaded) {
            std.debug.print(
                "lua: runtime-loaded dispatch (-Druntime=true) over the installed " ++
                    "provider named by an explicit load(source)\n",
                .{},
            );
        }
    }
}

/// Whether this target's OS has a dynamic linker at all, and therefore whether
/// it can carry a shared object.
///
/// Windows uses its PE/COFF loader without an interpreter path.
/// Other shared targets need a dynamic linker. WASI has neither.
fn targetHasDynamicLinker(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows or std.Target.DynamicLinker.kind(target.result.os.tag) != .none;
}

/// The linkage this build delivers, or a refusal when the target cannot carry
/// what was asked for.
///
/// There is no substitution here, deliberately. Upstream's `src/Makefile` builds
/// an archive and never a shared object (`src/Makefile:35`), so "deliver a
/// shared object" is this fork's addition and a caller who asks for it has asked
/// for a real shared object; handing back an archive under that name would be a
/// result the caller did not request and cannot tell from support. So a shared
/// request on a target whose OS has no dynamic linker stops here, with a
/// message that names the target, the reason and the way out.
///
/// `add_c_library`, `addGraph`, `add_programs` and `build` all resolve through
/// this one function, so the artifact, the declarations it is paired with and
/// the installed `lua.pc` cannot describe different linkages.
fn deliveredLinkage(
    target: std.Build.ResolvedTarget,
    requested: std.builtin.LinkMode,
) std.builtin.LinkMode {
    if (requested == .dynamic and !targetHasDynamicLinker(target)) {
        // `std.debug.panic` with a format string, not `@panic` on a
        // concatenated string: `@tagName` of a run-time tag is not comptime
        // known, and `++` on a slice being concatenated has to be, so the
        // message is formatted at run time. `std.debug.panic` takes the same
        // format and arguments as every other print in this file
        // (`lib/std/debug.zig:438`).
        std.debug.panic(
            "lua: -Dlinkage=dynamic was asked for {s}, which has no dynamic " ++
                "linker: std.Target.DynamicLinker.kind is .none for it, so it cannot " ++
                "carry a shared object at all. This build does not substitute a static " ++
                "archive for a requested shared object. Build that target with the " ++
                "default -Dlinkage=static, which is also what upstream's src/Makefile " ++
                "produces there and what its own src/loadlib.c and src/liolib.c " ++
                "branches expect.",
            .{@tagName(target.result.os.tag)},
        );
    }
    return requested;
}

/// Why a target has no buildable Lua here, or null when it has one.
///
/// A summary line and a long form, and nothing else: no warning, no fallback,
/// no substituted function. The shape is `lmdb/build.zig:458-536` and
/// `mpfr/build.zig:501-549`; the reasoning behind the one entry is written out
/// in full under "WASI and `os.tmpname`" in the module comment.
const Refusal = struct {
    /// One line, printed with the target triple in front of it.
    summary: []const u8,
    /// The long form printed before the build fails.
    detail: []const u8,
};

fn refusalFor(os_tag: std.Target.Os.Tag) ?Refusal {
    if (os_tag == .wasi) {
        return .{
            .summary = "Lua has no buildable configuration for this target: src/loslib.c's tmpnam configuration has no arm this toolchain's WASI libc can compile.",
            .detail =
            \\src/loslib.c:97-130 is upstream's own configuration block for
            \\'tmpnam', and it has exactly two arms. LUA_USE_POSIX selects
            \\mkstemp over <unistd.h> (:105-119); without it the ISO C arm is
            \\selected, which is tmpnam (:121-127). os.tmpname at :172-180 reads
            \\both unconditionally, so whichever arm is selected has to work.
            \\
            \\The outer guard at :103 is `#if !defined(lua_tmpnam)`, so the block
            \\is skipped when that macro is already defined. That is upstream's
            \\documented extension point, and it is not a switch: it is the
            \\(buffer, error) statement itself, the one :115-119 and :125 spell
            \\out. Setting it means this package writes the C that creates the
            \\temporary file, which is a substitute rather than a configuration,
            \\so it is not done here. LUA_TMPNAMBUFSIZE (:109, :124) and
            \\LUA_TMPNAMTEMPLATE (:111-113) only size and seed those two arms,
            \\and src/luaconf.h, src/Makefile and doc/readme.html name no tmpnam
            \\macro at all - that block is the whole of upstream's configuration
            \\for it, and src/Makefile has no wasm target to copy.
            \\
            \\Zig 0.16.0's WASI libc has neither arm. Both names are removed
            \\rather than deprecated, each behind `#ifdef
            \\__wasilibc_unmodified_upstream /* WASI has no temp directories */`:
            \\lib/libc/include/wasm-wasi-musl/stdio.h:148-154 guards tmpnam,
            \\leaving only a declaration marked
            \\__attribute__((__deprecated__("tmpnam is not defined on WASI"))),
            \\and stdio.h:64-67 guards L_tmpnam, so it is not defined at all;
            \\lib/libc/include/wasm-wasi-musl/stdlib.h:118-122 guards mkstemp,
            \\mkostemp and mkdtemp the same way. Nothing under lib/libc/wasi/
            \\defines either name - those headers are the only places the
            \\identifiers occur - so neither arm has an implementation to reach
            \\either, and silencing the deprecation would not turn L_tmpnam into
            \\a definition.
            \\
            \\In unchanged upstream bytes that is two errors, both in
            \\src/loslib.c: :173 sizes the buffer with the L_tmpnam the header
            \\does not define - and :13-17 includes errno.h, locale.h, stdlib.h,
            \\string.h and time.h, never stdio.h, so no include chain brings the
            \\macro in either - and :175 calls the tmpnam the header marks
            \\deprecated. LUA_USE_POSIX is not a way out: it moves the failure to
            \\:117, where mkstemp is equally undeclared, and it puts
            \\src/lua.c:47-57 back on sigaction, which this sysroot does not
            \\declare either.
            \\
            \\So the target is refused rather than patched past. No source is
            \\edited, tmpnam is not stubbed, and os is not dropped to make the
            \\rest of the library compile - dropping it would take os.time,
            \\os.date, os.clock, os.getenv, os.remove, os.rename and os.execute
            \\with it. Build for a target this package names a configuration
            \\for: x86_64-linux-gnu, aarch64-linux-gnu, riscv64-linux-gnu,
            \\aarch64-macos-none, x86_64-windows-gnu.
            \\
            \\This is a statement about this pinned src/loslib.c against this
            \\toolchain's WASI libc with nothing substituted for it, not a claim
            \\that WASI cannot host Lua. The cell comes back when upstream's
            \\:103 guard grows an arm for a platform with no temp directory, or
            \\when this toolchain's WASI libc stops removing mkstemp. Either is
            \\upstream's or the toolchain's to make, and this package makes
            \\neither.
            ,
        };
    }

    return null;
}

/// Prints why `target` cannot be built, and fails the build.
///
/// A real refusal, not a warning and not a stub: `zig build`, `zig build check`
/// and `zig build check -Dtarget=<this target>` all stop here, before a compiler
/// is invoked, and `zig build consumer -Dtarget=<this target>` stops in the
/// nested build it launches - which is this package's own `build()` again.
/// `addGraph` is the only caller.
fn refuseTarget(b: *std.Build, target: std.Build.ResolvedTarget) noreturn {
    const refusal = refusalFor(target.result.os.tag) orelse
        @panic("build.zig internal error: refusalFor returned null for a target addGraph refused");
    const triple = target.result.zigTriple(b.allocator) catch @panic("unspellable target");
    std.log.err("lua: {s}: {s}\n{s}", .{ triple, refusal.summary, refusal.detail });
    @panic("lua: refusing a target this package has no buildable configuration for");
}

/// Keeps the two halves of the matrix honest against each other.
///
/// The point of naming `refused_check_targets` is that the row is not quietly
/// absent, and the point of naming `check_targets` is that every row in it is
/// real. Both are re-derived here through the same `refusalFor` that
/// `refuseTarget` stops with, so a change that makes a refused target
/// buildable fails any build of this package rather than quietly shrinking what
/// `check` proves.
fn checkMatrixPartition(b: *std.Build) void {
    for (check_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        if (refusalFor(resolved.result.os.tag) != null) {
            @panic(b.fmt(
                "build.zig: {s} is in check_targets but this build refuses its operating system",
                .{resolved.result.zigTriple(b.allocator) catch @panic("unspellable check target")},
            ));
        }
    }
    for (refused_check_targets) |query| {
        const resolved = b.resolveTargetQuery(query);
        if (refusalFor(resolved.result.os.tag) == null) {
            @panic(b.fmt(
                "build.zig: {s} is in refused_check_targets but refusalFor no longer refuses it; move it to check_targets and prove it builds",
                .{resolved.result.zigTriple(b.allocator) catch @panic("unspellable check target")},
            ));
        }
    }
}
