# Notice

## Upstream Lua

Lua 5.5.1 is MIT-licensed, Copyright (C) 1994-2026 Lua.org, PUC-Rio. The grant appears in `src/lua.h` and `doc/readme.html`; the latter states Lua.org's credit requirement. Lua.org's download index says every file in the release tarball is distributed under this license, including files without an in-file notice. Include the Lua.org copyright notice in the product or its documentation.

| Path | Files | Licence | In-file notice |
|---|---:|---|---|
| `src/*.c` | 34 | MIT, Lua.org | `** See Copyright Notice in lua.h` |
| `src/*.h` except `src/lua.h` | 26 | MIT, Lua.org | `** See Copyright Notice in lua.h` |
| `src/lua.h` | 1 | MIT, Lua.org | Full grant |
| `src/lua.hpp` | 1 | MIT, Lua.org | None; covered by the tarball's blanket grant |
| `src/Makefile` | 1 | MIT, Lua.org | None; covered by the blanket grant |
| `Makefile` | 1 | MIT, Lua.org | None; covered by the blanket grant |
| `doc/readme.html`, `doc/contents.html`, `doc/manual.html` | 3 | MIT, Lua.org | PUC-Rio credit in footers; full grant in `readme.html` |
| `doc/lua.1`, `doc/luac.1`, `doc/*.css` | 5 | MIT, Lua.org | None; covered by the blanket grant |
| `doc/logo.png`, `doc/OSIApproved.png` | 2 | MIT, Lua.org | None; covered by the blanket grant |
| `README` | 1 | MIT, Lua.org | None; covered by the blanket grant |

All 75 upstream files are unmodified; no upstream files were removed. They comprise 63 files under `src/`, 10 under `doc/`, the root `Makefile`, and `README`. There are no per-file licence exceptions.

`README.upstream.md` is a fork-side, byte-identical copy of upstream `README`. It carries the same MIT grant but is not a 76th imported or digested file; `UPSTREAM.sha256` records `README` alone.

## Fork files

The following files are fork-authored and covered by the MIT grant in `FORK-LICENSE.md`; no upstream authorship is claimed:

- `build.zig`, `build.zig.zon`, `.gitignore`, `cross-test.profile.sh`
- `zig/root.zig`, `zig/translate.h`
- `tests.zig`, `smoke.zig`, `consumer/build.zig`, `consumer/build.zig.zon`, `consumer/src/main.zig`
- `runtime/loader.zig`, `runtime/library.zig`, `runtime/graph.zig`, `runtime/generate.zig`, `runtime/sync.h`, `runtime/sync.c`
- `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc`
- `tools/check-provenance.sh`
- `README.md`, `README.zig.md`, `NOTICE.md`, `UPSTREAM.md`, `UPSTREAM.sha256`, `FORK-LICENSE.md`, `FORK-NOTES.md`, `CHANGELOG.md`

`flake.lock` is driver-managed metadata, not fork-authored source; `devenv.lock` is absent. Lua's upstream grant and notice remain in the source tree, and the package's licence records include both.
