/* The one header this package translates.
 *
 * `zig build` runs translate-c over this file, and what that translation
 * becomes is the `c` module the Zig facade in zig/root.zig imports.  Its whole
 * job is to name the public headers of the library this build compiles.
 *
 * Which headers those are
 * -----------------------
 * Lua installs five headers (doc/readme.html, "Installing Lua" ->
 * "include: lua.h luaconf.h lualib.h lauxlib.h lua.hpp"), and this file names
 * three of them:
 *
 *   lua.h      the core API.  It includes luaconf.h itself
 *              (src/lua.h:27-29), so every configuration macro that decides
 *              the numeric ABI and the export decoration is pulled in by
 *              including it, exactly as every C consumer gets them.
 *   lauxlib.h  the auxiliary library, which includes lua.h
 *              (src/lauxlib.h:12-13) and therefore adds nothing that is not
 *              already reachable.
 *   lualib.h   the standard-library openers, which includes lua.h
 *              (src/lualib.h:11).
 *
 * All three are included whole, with their own include guards, so this wrapper
 * cannot disagree with the real headers by omission and cannot re-declare a
 * prototype with a different type.
 *
 * Why luaconf.h is not listed separately
 * --------------------------------------
 * It is a configuration header, not a declaration surface: nothing in it
 * declares a function.  It reaches the translation through lua.h, which is what
 * an installed C consumer gets too, so the macros the translated constants
 * (`LUA_VERSION*`, `LUA_T*`, `LUA_MULTRET`, `LUA_*LIBK`, ...) are computed
 * from are the same ones the compiled C saw.
 *
 * Why lua.hpp is not listed
 * ------------------------
 * It is C++ only (src/lua.hpp:1-9: it opens `extern "C" {` and includes the
 * three headers above).  translate-c compiles C, so including it would put a
 * C++ construct on a C translation line.  It is still installed, unchanged, by
 * build.zig, because it is one of upstream's five installed headers and a C++
 * consumer of the installed tree needs it.
 *
 * What is deliberately not here
 * -----------------------------
 * A copy of any declaration, and no macro of this build's own.
 *
 * The `LUA_USE_*` macros are on the compile line, not here, and not in the
 * header, because they describe *this* build's platform rather than what the
 * interface is - the same reason upstream puts `SYSCFLAGS` in src/Makefile and
 * not in luaconf.h.  They are defined once in build.zig and given to the
 * library's own compilation and to this translation alike, so the declarations
 * below and the code that implements them cannot be built for two different
 * platforms.  See build.zig, `platformMacros`.
 *
 * `LUA_BUILD_AS_DLL` is the one macro a consumer may need to repeat, and it is
 * *not* defined here either: it turns `LUA_API` from `extern` into a
 * `__declspec` decoration (src/luaconf.h:305-317), which is a fact about how
 * the library was built rather than about the interface.  build.zig puts
 * `LUA_BUILD_AS_DLL` (with `LUA_CORE` or `LUA_LIB` when it is the build that
 * *is* the library) on the C compile lines, `LUA_BUILD_AS_DLL` alone on this
 * translation for a shared build, and the installed `lua.pc` carries it in
 * `Cflags` for a shared install, which is how a C consumer gets the same
 * `dllimport` answer without repeating the flag.
 */

#ifndef LUA_TRANSLATE_H
#define LUA_TRANSLATE_H

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#endif /* LUA_TRANSLATE_H */