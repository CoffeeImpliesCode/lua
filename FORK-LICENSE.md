# FORK-LICENSE.md — the grant for this fork's own files

[`NOTICE.md`](NOTICE.md) is the inventory: which files are upstream's, which are
this fork's, and which term covers each. This file is the grant itself, for the
second group only.

## 1. The native source is not covered by anything below

The 75 files under `src/`, `doc/`, either `Makefile` and `README` are Lua's,
whole from `lua-5.5.1.tar.gz` and never edited. They are MIT,
Copyright (C) 1994-2026 Lua.org, PUC-Rio, under the grant in
`src/lua.h:523-544`. Nothing in this file re-grants, narrows, widens or
conditions that term, and nothing here
asserts that Lua.org, PUC-Rio or any named author wrote, reviewed or endorses a
line of fork code.

## 2. The fork-authored material

Everything else in this repository — the Zig build, the typed module and its
tests, the example, the consumer package, the runtime-loading route, the
packaging, the integrity script and the documentation — was written for this
fork. The runtime-loading route is the six files under `runtime/`: the reusable
loader, this SDK's descriptor, the build half that wires them together, the
build-time generator, and the two C files that supply the synchronization the
descriptor binds. All six are fork work under this grant; none of them is
upstream material and none is derived from a third-party source.

### Grant

**Those files are released under the MIT License**, matching the primary
upstream term of this project, whose text is:

```
MIT License

Copyright (c) 2026 the contributors to this fork

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

The same obligation MIT imposes on Lua applies to this text: keep the notice
with copies of the fork's files.

### Authority for that grant

The owner of this repository authorized per-project licensing for fork-authored
additions as part of the SDK contract migration, with the term chosen per
project to match that project's primary upstream terms where that is
appropriate. Lua's primary upstream term is plain MIT, so MIT is the choice.
The authorization is recorded here and in `NOTICE.md`; the term above is the
owner's, reached by that authorization and not by any upstream grant.

The owner is not named and no individual copyright holder is invented: the
copyright line above is deliberately the collective one.

### SPDX identifier

```
MIT
```

The plain registered identifier, with no `LicenseRef-` wrapper. That is a
deliberate distinction, not a shortcut: a fork whose primary term carries added
conditions needs an identifier that names them, because a consumer scanning for
`MIT` would otherwise stop reading and miss the conditions. **Lua's term is
bare MIT** — the same grant, the same one condition, no exceptions
(`NOTICE.md`, "Per-file exceptions") — so `MIT` is the accurate identifier and
inventing a `LicenseRef-` would misrepresent a plain grant as a variant one.

Every fork-authored **source, build, packaging and script** file carries
`SPDX-License-Identifier: MIT` on its own first comment line — nineteen files,
named one by one in [`NOTICE.md`](NOTICE.md). The documentation and digest
records do not carry a tag: they are prose and data, and `NOTICE.md` names each
of them explicitly so that a scanner finding no identifier in `README.md` reads
a recorded reason rather than an apparent gap.

### What this does not do

* It does not re-license, sublicense or add a condition to any Lua file.
* It does not assert that Lua.org, PUC-Rio, R. Ierusalimschy, L. H. de Figueiredo
  or W. Celes authored, reviewed, endorsed or is affiliated with the fork's
  files.
* It does not discharge Lua's attribution obligation. A consumer who ships a
  Lua 5.5.1 binary, static or shared library, `lua`/`luac` executable or header
  still owes the Lua.org notice; see `NOTICE.md` for where it travels.
* It does not claim that MIT is the only term the owner could have chosen for
  independently authored work. It is the term chosen, and it happens to match
  upstream's.

## 3. Material carried but not authored here

There is none. This repository vendors no third-party code, no downloaded
header and no external data file. The 75 files listed in `UPSTREAM.sha256` are
the complete upstream material, and nothing was added to them.

The two files this build generates are not carried material either, and the
distinction is worth keeping exact rather than dropping a category to make the
sentence short. Under `-Druntime`, `runtime/generate.zig` writes the dispatch
and its patched translation through `Run.addOutputFileArg`
(`runtime/graph.zig:412-416`), so both land in the build cache rather than in
this tree, and they are built from the translation of `zig/translate.h` and
upstream's own headers that this same build has just produced for the target
being built. Nothing is fetched to make them, no third-party code is in them,
and neither is installed or shipped: every file under `runtime/` in this tree
is a fork-authored file under section 2.

## 4. Why a separate file at all

`NOTICE.md` names which fork-authored files carry an `SPDX-License-Identifier`
line and which carry the same grant in prose without one. This file exists so
that the authority, the grant text and the limits of that grant live in one
place, next to the inventory rather than scattered across the files themselves.