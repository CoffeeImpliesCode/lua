# Source-only package derivation for the Lua SDK.
#
# One file, consumed by both flake.nix and devenv.nix, so the two entry points
# cannot describe different packages. It builds nothing but this repository: the
# native source is upstream's `src/`, which is the complete Lua 5.5.1 core,
# standard-library and program closure imported whole from the release tarball,
# and build.zig owns every compile flag and the whole installed layout. Nothing
# here restates a C flag, fetches a tarball, reaches into a sibling checkout, or
# installs an artifact of its own. The one edit it makes is the rpath of the ELF
# files the build installed: Zig records its own build cache there, and that
# directory does not exist once a binary is installed.
#
# No lock file is written here. `flake.lock` and `devenv.lock` belong to the
# driver.
#
# SPDX-License-Identifier: MIT
# See FORK-LICENSE.md for what that identifier covers, and NOTICE.md for the
# Lua.org terms that cover everything in src/ and doc/.

{ lib
, stdenv
, zig
, patchelf
  # Zig's own `std.builtin.LinkMode` spelling, passed straight through as
  # `-Dlinkage`. "static" and "dynamic" are two variants of one derivation, and
  # `""` passes nothing at all so the SDK's own default policy runs unchanged.
  # Lua's upstream Makefile builds only an archive, so static is this fork's
  # default and `.shared` is the separate variant.
, linkage ? "static"
, optimize ? "ReleaseSafe"
}:

let
  requestedLinkage =
    if builtins.elem linkage [ "" "static" "dynamic" ] then linkage
    else throw "package.nix: linkage must be \"\", \"static\" or \"dynamic\", not ${toString linkage}";

# Everything except build outputs, version control and developer-tool state.
# Filtering by directory name rather than by an allow list means a file added
# here later is packaged without editing this file, while `.zig-cache/`,
# `zig-out/`, `.devenv/`, `.direnv/` and `result` stay out of a published output
# at any depth, including under consumer/. The upstream manuals, man pages,
# images and both upstream Makefiles are deliberately kept: they are upstream
# material with digests in UPSTREAM.sha256, and the audit surface is the whole
# upstream tree.
src = lib.cleanSourceWith {
  src = ./.;
  filter = path: _type:
    let name = builtins.baseNameOf (toString path); in
    !(lib.elem name [
      ".git"
      ".direnv"
      ".devenv"
      ".zig-cache"
      "zig-cache"
      "zig-pkg"
      "zig-out"
      "result"
    ]);
};

# patchelf rewrites ELF rpaths and does not read Mach-O, so the rpath
# normalisation in the install phase exists for ELF targets only, and the tool is
# a build input exactly where that code runs.
isElfTarget = !stdenv.hostPlatform.isDarwin;
in

# These packages build for the compiler's own native target. A cross build here
# would mean hand-building a libc-suffixed triple that has to track nixpkgs, so
# this derivation refuses one instead of silently producing a host-architecture
# library under a foreign name. The comparison is against stdenv's own
# platforms, which are pure values; `builtins.currentSystem` is not evaluable
# in a sandbox and is not used. A remote builder is unaffected: this compares
# build against host, not against any particular machine.
assert stdenv.buildPlatform.system == stdenv.hostPlatform.system;

stdenv.mkDerivation {
  pname = "lua";
  version = "5.5.1";

  inherit src;

  strictDeps = true;
  dontPatch = true;

  # The real work is one `zig build install` in installPhase below. Disabling
  # configure and build phases keeps the Zig setup hook from running a first,
  # differently-flagged build of its own; `dontInstall` is deliberately NOT set,
  # because that is what would disable the real install phase.
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ zig ] ++ lib.optional isElfTarget patchelf;

  # Lua links against the C library, the C math library and — where the
  # platform configuration defines LUA_USE_DLOPEN — `dlopen`, which `loadlib.c`
  # uses to load C modules. On Linux readline is not a link-time dependency at
  # all: `lua.c` dlopens it at startup when LUA_USE_READLINE is not defined by
  # the build, and falls back to fgets when it cannot. This is the whole of the
  # native dependency closure; nothing else is propagated.
  propagatedBuildInputs = [ stdenv.cc.libc ];

  # The driver owns every gate for this SDK, and a Nix build is not a
  # verification receipt. No check phase is declared here rather than a check
  # phase that runs something smaller than the real gates; the commands that do
  # verify this package are in README.md and CHANGELOG.md.
  doCheck = false;
  dontUseZigCheck = true;

  installPhase = ''
    runHook preInstall

    # Both caches go under the Nix-provided TMPDIR, outside the unpacked source
    # tree, so a build cannot write into $src and so two parallel derivations
    # cannot share state. Any caller-supplied cache variables are left alone:
    # they are the caller's scratch, not this file's to clear.
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"

    # build.zig owns the source list, the C flags, the LUA_USE_* platform
    # configuration, the generated pkg-config file and every installed path.
    # Declaring any of them here as well would create a second place where they
    # can disagree with the build graph.
    zig build install \
      --prefix "$out" \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Doptimize=${optimize} \
      -Dcpu=baseline \
      ${lib.optionalString (requestedLinkage != "") "-Dlinkage=${requestedLinkage}"}

    # Zig records the build cache in the rpath of anything that links a dynamic
    # artifact it has just built (lib/std/Build/Step/Compile.zig:1192-1199), so
    # an installed binary names a directory that is gone, and Nix rejects an
    # installed file that names its build directory at all. Both Zig caches above
    # are under $TMPDIR, so dropping those entries and no other removes it: the
    # $ORIGIN/../lib build.zig adds, and every store path a real dependency
    # needs, stay. Symlinks are resolved first so a soname link is rewritten
    # through to the object and never replaced by a copy of it.
    ${lib.optionalString isElfTarget ''
      for elf in "$out"/bin/* "$out"/lib/*.so*; do
        [ -f "$elf" ] || continue
        elf=$(readlink -f "$elf")
        rpath=$(patchelf --print-rpath "$elf") || rpath=""
        kept=""
        rest=$rpath
        while [ -n "$rest" ]; do
          entry="''${rest%%:*}"
          case "$entry" in
            "$TMPDIR"/*) ;;
            *) if [ -z "$kept" ]; then kept=$entry; else kept=$kept:$entry; fi ;;
          esac
          if [ "$entry" = "$rest" ]; then rest=""; else rest="''${rest#*:}"; fi
        done
        [ "$kept" = "$rpath" ] || patchelf --set-rpath "$kept" "$elf"
      done
    ''}

    runHook postInstall
  '';

  # The layout this derivation produces is the build graph's, not this file's:
  # $out/lib/liblua.a (or liblua.so), $out/include/{lua,luaconf,lualib,
  # lauxlib}.h plus lua.hpp, $out/lib/pkgconfig/lua.pc, $out/bin/{lua,luac},
  # $out/share/man/man1/{lua,luac}.1 and $out/share/licenses/lua/ with the
  # upstream grant and this fork's records. Both variants keep it; only the
  # artifact kind differs. Nothing is copied or generated by hand here, so
  # `zig build install --prefix $out` and `nix build` produce one layout by
  # construction rather than two that have to be kept in agreement.

  enableParallelBuilding = true;

  meta = {
    description = "Lua 5.5.1, the embeddable scripting language, built from the official release sources";
    longDescription = ''
      The complete Lua 5.5.1 release source -- core VM, auxiliary library,
      ten standard libraries, the standalone interpreter and the standalone
      compiler -- compiled from the tarball's own src/ directory with Zig, with
      no autotools, no CMake and no build-time download. Ships the library, both
      programs, the public headers, the man pages and a pkg-config file.
    '';
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "lua";
  };
}