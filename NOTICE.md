# Notice

Two separate things are recorded here: what the canonical native source is and
which grant covers each of its files, and what this fork wrote on top of it.
[`FORK-LICENSE.md`](FORK-LICENSE.md) carries the grant for the second group.

## The upstream term

Lua is MIT-licensed, and this is the plain two-clause MIT text with no added
condition, no exception file and no alternative grant. The authoritative copy in
this tree is the one in the source's own public header:

* `src/lua.h:523-544` — the copyright notice and the full permission and
  warranty text.
* `doc/readme.html:299-322` — the same grant in HTML, with the "only
  requirement" credit clause that upstream states in prose just above it.
* `doc/contents.html:35-37` and `doc/manual.html:22-24` — the manuals' footers,
  which credit Lua.org and link the Lua licence page.

lua.org's own download index states the distribution rule for the whole
tarball, not only for the files that repeat the notice
(<https://www.lua.org/ftp/>, read 2026-10-04): *"All files are distributed
under this license"*, linking <https://www.lua.org/license.html>. That blanket
statement is what covers the files with no notice of their own, listed below.

Upstream also states the one obligation in prose
(`doc/readme.html:293-294`): if you use Lua, give Lua.org credit by including
the appropriate copyright notice in your product or its documentation. The MIT
text's "included in all copies or substantial portions" clause says the same
thing, so this SDK keeps the notice in every shipped artefact.

## Inventory of the upstream files

75 files, 1416954 bytes, digests in [`UPSTREAM.sha256`](UPSTREAM.sha256). Every
one is **MIT, Copyright (C) 1994-2026 Lua.org, PUC-Rio.**

| Path | Count | Term | Notice in the file |
|---|---:|---|---|
| `src/*.c` | 34 | MIT, Lua.org | `** See Copyright Notice in lua.h` |
| `src/*.h` except `lua.h` | 26 | MIT, Lua.org | `** See Copyright Notice in lua.h` |
| `src/lua.h` | 1 | MIT, Lua.org | the full grant, `src/lua.h:523-544` |
| `src/lua.hpp` | 1 | MIT, Lua.org | **none in the file** — 10 lines of `extern "C"` includes, covered by the tarball's blanket statement |
| `src/Makefile` | 1 | MIT, Lua.org | **none in the file** — covered by the blanket statement |
| `Makefile` | 1 | MIT, Lua.org | **none in the file** — covered by the blanket statement |
| `doc/readme.html`, `doc/contents.html`, `doc/manual.html` | 3 | MIT, Lua.org | PUC-Rio credit in the footer; full grant in `readme.html` |
| `doc/lua.1`, `doc/luac.1`, `doc/*.css` | 5 | MIT, Lua.org | **none in the file** — covered by the blanket statement |
| `doc/logo.png`, `doc/OSIApproved.png` | 2 | MIT, Lua.org | **none in the file** — covered by the blanket statement |
| `README` | 1 | MIT, Lua.org | **none in the file** — covered by the blanket statement |

`README.upstream.md` is a fork-side copy of `README`, kept under this
repository's naming convention and byte-identical to it. It carries the same
MIT grant and is deliberately **not** a 76th digested file: `UPSTREAM.sha256`
records `README` alone, and `tools/check-provenance.sh:59-63` is what proves
the copy has not drifted from the original. The 75 above is therefore the
whole of the upstream material — 63 files under `src/`, 10 under `doc/`, the
root `Makefile` and `README`.

The count that matters for auditing is the notice convention itself: **60 of the
63 files in `src/` carry the line `** See Copyright Notice in lua.h`, and the
three that do not are `lua.h` (which *is* the notice), `lua.hpp` (which has no
comment block at all) and `Makefile` (a makefile). Nothing outside those three
carries a second grant.

`doc/logo.png` is Lua's logo and `doc/OSIApproved.png` is the Open Source
Initiative approval badge that `doc/readme.html` displays. Neither carries its
own licence text here; both are part of the tarball and therefore part of the
blanket grant, and both travel unmodified.

## Per-file exceptions

**None.** Lua's grant has no dual-licensing clause, no public-domain
dedication, no copyleft component and no per-file carve-out, so this inventory
does not have the shape that a mixed-terms tree needs — one label covering
everything, or a GPL/LGPL split between core and tooling. Every byte of Lua's
own material is MIT, and the single attribution obligation is the notice above.

That is a statement about *this* release, not a claim about all of Lua's
history: earlier and later work by the same authors is not covered by it.

## What this fork changed in upstream files

**Nothing.** No file under `src/`, `doc/`, or either `Makefile` has been
edited, and `README` is byte-identical to the tarball's copy of itself in
`README.upstream.md`. `UPSTREAM.sha256` plus the exact-file-set check in
`tools/check-provenance.sh` are what make that claim checkable rather than
asserted, and any future native edit has to move those digests in the same
change, with a numbered entry in [`CHANGELOG.md`](CHANGELOG.md).

`STATUS`: `SOURCE-CONFIRMED` from the recorded digests. That is a claim about
bytes and about what this file asserts about them, not about a build, and no
build result is recorded here. [`README.md`](README.md) carries the observed
runs — three of the four runtime/linkage combinations, each row naming what was
run and what came out — and marks every gate it does not cover
`PENDING-VERIFICATION`. Those are that file's observations; this inventory does
not restate or extend them.

## Fork-specific notice

Every file below was written for this fork. None of it carries an upstream
copyright, no upstream permission is claimed over it, and it is released under
the MIT terms recorded in [`FORK-LICENSE.md`](FORK-LICENSE.md):

* `build.zig`, `build.zig.zon`, `.gitignore`, `cross-test.profile.sh`
* `port017.zig`, `port017_make.zig` and `port017_runtimes.zig`, the
  configure/make compatibility helpers
* `zig/root.zig`, the typed facade, and `zig/translate.h`, the aggregate
  translation header this build runs `translate-c` over
* `tests.zig`, `smoke.zig`, `consumer/build.zig`, `consumer/build.zig.zon`,
  `consumer/src/main.zig`
* `runtime/` — the load-at-runtime route, as the six files it holds today.
  `loader.zig` is the reusable state machine and platform layer, holding no
  per-SDK name; `library.zig` is this SDK's descriptor, the namespaced
  synchronization binding and the one load-time check; `graph.zig` is the
  build half that wires them together and substitutes `createModule` for the
  translation's own; `generate.zig` is the build-time generator that writes
  the dispatch from the real translation output for the target being built,
  through `Run.addOutputFileArg`, so the generated file lands in the build
  cache and this directory holds no generated source. `sync.h` and `sync.c`
  are the two C files that give the loader its process-global mutex, condition
  variable and thread identity under an `RT_SYNC_PREFIX` this SDK sets to
  `lua_rt` (`runtime/graph.zig:116`, `runtime/graph.zig:364-367`); `sync.c` is
  compiled into the dispatch and `sync.h` is the only header the route
  compiles C against. All six are fork work under this grant; none of them is
  upstream material, and `sync.c` is not a substitute for any upstream unit.
* `package.nix`, `flake.nix`, `devenv.nix`, `devenv.yaml`, `.envrc`
* `tools/check-provenance.sh`
* this file, `README.md`, `README.zig.md`, `UPSTREAM.md`, `UPSTREAM.sha256`,
  `FORK-LICENSE.md`, `CHANGELOG.md`, `FORK-NOTES.md`

`flake.lock` is **present** in this tree and carries one `github:NixOS/nixpkgs`
pin at revision `c7def046b9a883d46974757852106483d741586f`. It was written by
the driver rather than by this fork's tooling, and it grants nothing: it is a
lock record, not authored material, and it belongs to neither group above.
`devenv.lock` is **absent from this tree**, because `devenv.yaml` pins its
nixpkgs revision in source; there is no second lock to write and none is
invented here. `build.zig.zon`'s `.paths` is the package's file filter, and the
one rule that governs it is that every path it names must exist: `zig fetch`
hashes the named paths, so naming `devenv.lock` while it is absent would fail
the fetch rather than record an absence.

### Which of those files carry the SPDX tag, and which do not

Nineteen fork-authored files above carry `SPDX-License-Identifier: MIT` on
their own first comment line: `build.zig`, `build.zig.zon`, `zig/root.zig`,
`tests.zig`, `smoke.zig`, `consumer/build.zig`, `consumer/src/main.zig`, all
six files of `runtime/`, `tools/check-provenance.sh`, `package.nix`,
`flake.nix`, `devenv.nix`, `devenv.yaml` and `.envrc`. That set was read out of
the files rather than assumed.

The rest carry the same grant without a tag, and are named here rather than
left for a scanner to read as unlicensed. Five are comment-capable text whose
grant is this inventory and [`FORK-LICENSE.md`](FORK-LICENSE.md):
`zig/translate.h`, `cross-test.profile.sh`, `.github/workflows/verify.yml`,
`.gitignore` and `consumer/build.zig.zon`. The eight documentation and digest
records — this file, `README.md`, `README.zig.md`, `UPSTREAM.md`,
`UPSTREAM.sha256`, `FORK-LICENSE.md`, `CHANGELOG.md` and `FORK-NOTES.md` — are
prose and data with no comment position a tag is expected in, and their grant
is the same MIT text.

Upstream's attribution obligation is unaffected by any of this: a consumer who
receives a Lua 5.5.1 binary or static library still owes the Lua.org notice,
and the installed tree carries it. `share/licenses/lua/` holds
`doc/readme.html` and `src/lua.h` — upstream's own grant and notice — together
with `README`, `NOTICE.md`, `FORK-LICENSE.md`, `UPSTREAM.md`,
`UPSTREAM.sha256`, `FORK-NOTES.md` and `CHANGELOG.md`: nine files, exactly
`licence_records` in `build.zig:546-556`, which is also what `package.nix`
installs because it runs the same `zig build install`.