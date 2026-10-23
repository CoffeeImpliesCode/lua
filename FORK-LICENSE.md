# FORK-LICENSE.md — grant for fork-authored files

[`NOTICE.md`](NOTICE.md) inventories upstream and fork-authored files and their terms. This file grants rights for fork-authored files only.

## Scope

The 75 files under `src/`, `doc/`, both `Makefile`s, and `README` are unmodified Lua 5.5.1 source from `lua-5.5.1.tar.gz`. They remain under MIT, Copyright (C) 1994-2026 Lua.org, PUC-Rio, as granted in `src/lua.h`. This grant does not cover or relicense them.

Every other file in this repository is fork-authored under this grant: the Zig build and facade, tests, example, consumer package, runtime loader, packaging, integrity script, and documentation. The six files under `runtime/`—the reusable loader, SDK descriptor, build graph, generator, and two synchronization C files—are fork-authored, not upstream material or third-party derivations.

This grant does not imply authorship, review, endorsement, or affiliation by Lua.org, PUC-Rio, R. Ierusalimschy, L. H. de Figueiredo, or W. Celes.

## Grant

Fork-authored files are released under the MIT License, matching Lua's primary upstream term. The repository owner authorized this per-project grant. The copyright notice names the contributors collectively; the owner is unnamed.

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

## SPDX identifier

```
MIT
```

Plain MIT; no exceptions. Nineteen fork-authored source, build, packaging, and script files carry `SPDX-License-Identifier: MIT`; `NOTICE.md` lists them. Documentation and digest records have no SPDX tag and are listed there too.

Distributing a Lua 5.5.1 binary, library, executable, or header still requires Lua.org's notice; see `NOTICE.md`.

The 75 files in `UPSTREAM.sha256` are the complete upstream material; no other third-party code, downloaded headers, or external data are included.

Under `-Druntime`, `runtime/generate.zig` writes the dispatch and patched translation into the build cache from the build's translation of `zig/translate.h` and upstream headers. Neither output is checked into this tree, installed, or shipped. They use no fetched or third-party code.
