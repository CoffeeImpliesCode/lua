# cross-test settings profile for the Lua SDK.
#
# `cross-test` looks for this file at the root of the project it is run from
# (or names it with --profile; --no-profile ignores it). It is trusted Bash that
# the harness `source`s, so this file is *settings only*: ordinary variable
# assignments and nothing else. No command runs, no compiler is probed, and no
# path in here names a host.
#
# There is deliberately no CROSS_MATRIX. The published 53-platform Zig 0.16
# Tier 1/2 table is the matrix this package is checked against, and a matrix
# named here would replace it. There is no TARGETS array either, for the same
# reason: a subset selected here would narrow the run rather than add to it.
# Both belong on the command line, where --targets selects from the active
# matrix and never adds to it.
#
# CROSS_BUILD_STEP stays the standard `test` step, which is what this profile
# states explicitly. There are no `cross_build_command` / `cross_artifact`
# hooks here, so the harness keeps its standard Zig-build mode and runs
# `zig build test -Dtarget=TARGET` per target with a fresh cache. What that
# means for a given target is the harness's decision, not this package's: a
# host target runs, a foreign target runs under whatever executor the harness
# detects (QEMU user mode, Wine, wasmtime), and a foreign target with no
# executor is reported as build-only coverage -- compiled, never executed, and
# never counted as a pass. `build.zig` gives the test binary a Run step for
# every target, which is what leaves that choice open.
#
# A target graph compiles the whole 32-unit closure of `src/Makefile`'s `CORE_O`
# and `LIB_O`, translates `lua.h`, `lauxlib.h` and `lualib.h`, and links the
# facade and the test root. Keep a few build jobs available: Lua's `lparser.c`,
# `lcode.c`, `lvm.c` and `lgc.c` are four of the largest translation units in
# the tree and each matrix cell compiles all of them.
#
# Nothing here narrows the gate to what is expected to work. Which platforms
# Lua itself supports is decided by `src/luaconf.h` - POSIX, Windows and its
# C89 numeric path, and no dynamic loading where the platform has none - and
# `build.zig` resolves those macros from the target being built. A cell that
# fails is a fact to record and diagnose; it is not a reason to drop the cell,
# sample the tests or remap Debug to an optimized mode to make it pass.

CROSS_BUILD_STEP=test
CROSS_BUILD_JOBS=4
CROSS_BUILD_TIMEOUT=3600
CROSS_TIMEOUT=1800