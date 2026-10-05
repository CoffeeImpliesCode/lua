# Upstream

Which upstream this SDK is built from, what was taken from it byte for byte,
and what was not taken at all.

## Canonical source

| | |
|---|---|
| Project | Lua, PUC-Rio |
| Authoritative site | <https://www.lua.org/> |
| Artifact | `lua-5.5.1.tar.gz` |
| URL | <https://www.lua.org/ftp/lua-5.5.1.tar.gz> |
| Released | 2026-07-24 |
| Size | 398643 bytes |
| sha256 | `1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce` |
| Digests and sizes listed at | <https://www.lua.org/ftp/> (read 2026-10-04) |

`SOURCE-CONFIRMED`: the digest, the date and the size above are the values
printed in the checksum column of lua.org's own download index. The same digest
is the release pin the SDK migration brief carries.

There is no VCS import and therefore no commit SHA, because a release tarball
is what this SDK is built from; see "Import mechanism".

Lua also publishes its working sources (`<https://www.lua.org/git/lua.git>`,
mirrored at `github.com/lua/lua`) and a separate manuals package
(`refman-5.5.tar.gz`, 2026-08-25, sha256
`4b848ee1f027a32a316021de333f60e4e7658a3e9e861180ff00e29c70a62613`). Neither
is a source for this tree: `doc/` here is the copy inside the release tarball,
not a separately fetched manuals package.

## What upstream is

A complete, self-contained implementation of the Lua language — 26 423 lines of
C and 5 779 lines of headers as imported: a virtual machine, a parser and code
generator, the garbage collector, the undump/loader, the debug interface, the
auxiliary library and ten standard libraries. There is no external dependency
beyond a C89 compiler, the C math library and, where the platform
configuration asks for it, `dlopen` for C modules.

Upstream's build system is two `Makefile`s: one at the root that drives
`src/` and `doc/` and owns installation, one in `src/` that owns compilation.
This SDK uses neither. `build.zig` compiles the same source list; see README.md,
"Native-build deviations".

## The preserved upstream README

The release tarball ships a file called `README`, which is upstream's own
release note and **not** a fork README. It is preserved here twice, unaltered:

* `README` — the imported original, exactly as the tarball carries it.
* `README.upstream.md` — the same bytes under the name the rest of this
  repository uses for a preserved upstream README.

Both are 151 bytes with sha256
`7805901a81d7b26021652c3b81cb2793bcea88f940b13ea66f901fb8be544fba`, and
`tools/check-provenance.sh` fails if they ever differ. The canonical fork
document is [`README.md`](README.md); upstream's own installation and
licence notes are in `doc/readme.html`, which also travels unaltered.

## What is in the tarball

75 files, 1416954 bytes after extraction. The whole project is imported; nothing
is dropped for size, and nothing is dropped for being uncompiled by this fork.

| Path | Files | What it is |
|---|---:|---|
| `src/*.c` | 34 | 32 library translation units, plus `lua.c` (interpreter main) and `luac.c` (compiler main) |
| `src/*.h` | 27 | 4 public headers, 23 internal ones |
| `src/lua.hpp` | 1 | C++ convenience wrapper |
| `src/Makefile` | 1 | upstream's own compile rules |
| `Makefile` | 1 | upstream's own platform rules and installation |
| `doc/` | 10 | reference manual, readme, man pages, stylesheets, images |
| `README` | 1 | upstream's release note |

Per-file digests are in [`UPSTREAM.sha256`](UPSTREAM.sha256), which is the
complete set and not a selection.

## The core closure, as upstream lists it

`src/Makefile:36-37` names the objects that make `liblua.a`. That is the
closure this SDK compiles, and it is read out of upstream rather than derived:

* **Core** (`CORE_O`, 20): `lapi lcode lctype ldebug ldo ldump lfunc lgc llex
  lmem lobject lopcodes lparser lstate lstring ltable ltm lundump lvm lzio`
* **Libraries** (`LIB_O`, 12): `lauxlib lbaselib lcorolib ldblib liolib
  lmathlib loadlib loslib lstrlib ltablib lutf8lib linit`
* **Programs**: `lua.c` and `luac.c`, each linked against the above.

The four public headers are `lua.h`, `luaconf.h`, `lualib.h`, `lauxlib.h`;
`lua.hpp` includes the first, second and fourth inside `extern "C"`. The other
23 headers are internal to the implementation, and upstream's own comment
convention (`** See Copyright Notice in lua.h`) is what NOTICE.md follows.

## There is no upstream test suite in the tarball

The release tarball contains no test suite. `src/Makefile:69-70` defines

```make
test:
	./$(LUA_T) -v
```

which runs the interpreter and prints its version, and `doc/readme.html` says
the same thing in prose ("this will run the interpreter and print its
version"). Lua's test library — `ltests.c`, `lmem.c`'s test hooks and the rest —
lives in the working repository, not in a release tarball.

Two consequences are binding here. This SDK does **not** claim to ship, build
or run an upstream test suite, and no build step fetches one to stand in for
it: a fetched suite would be a different source tree than the release this SDK
pins, with no recorded digest. The SDK's own behavioural tests are independent
known answers and are described in README.zig.md.

## Nothing is generated at build time

Lua has no configure step, no generated header and no generated table. That is
not an omission in this port: there is nothing for a build step to generate.
`src/ljumptab.h`, the interpreter's dispatch table, is a checked-in source
file, and `src/ljumptab.h:21-25` carries the `sed` command upstream uses to
refresh it when `lopcodes.h` changes. A future release that regenerates it
would ship a new checked-in copy, and its digest would change with it.

## Import mechanism

A release tarball, imported whole. There is no upstream Git history in this
tree, no commit SHA to record, and no patch series: the tree either matches the
tarball or a deviation is recorded. `UPSTREAM.sha256` is the check that it does.

If a future wave re-syncs to another release, the correct sequence is: download
the new tarball, verify its published sha256, replace the imported files, update
`UPSTREAM.sha256`, `UPSTREAM.md`, `NOTICE.md` and `README.md`, and add a
numbered `CHANGELOG.md` entry — in one change.

## Third-party material in this repository

None. There is no vendored dependency, no generated table and no downloaded
header. Every file here other than the 75 upstream files listed above was
written for this fork.