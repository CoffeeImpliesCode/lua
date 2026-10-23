# Source-only derivation shared by flake.nix and devenv.nix.
# SPDX-License-Identifier: MIT
# See FORK-LICENSE.md for covered files and NOTICE.md for Lua.org terms in src/ and doc/.

{ lib
, stdenv
, zig
, patchelf
  # Static matches upstream; "" defers to build.zig, and dynamic selects shared linkage.
, linkage ? "static"
, optimize ? "ReleaseSafe"
}:

let
  requestedLinkage =
    if builtins.elem linkage [ "" "static" "dynamic" ] then linkage
    else throw "package.nix: linkage must be \"\", \"static\" or \"dynamic\", not ${toString linkage}";

# Exclude VCS and generated state while retaining the complete upstream source tree.
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

# Apply the rpath rewrite only to non-Darwin targets; patchelf cannot read Mach-O.
isElfTarget = !stdenv.hostPlatform.isDarwin;
in

# Refuse cross builds using stdenv values; builtins.currentSystem is unavailable in the sandbox.
assert stdenv.buildPlatform.system == stdenv.hostPlatform.system;

stdenv.mkDerivation {
  pname = "lua";
  version = "5.5.1";

  inherit src;

  strictDeps = true;
  dontPatch = true;

  # Disable configure/build to avoid a differently flagged Zig hook build; keep the real install phase.
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ zig ] ++ lib.optional isElfTarget patchelf;

  # Lua needs libc, libm, and dl where upstream enables dlopen; Linux loads readline at runtime.
  propagatedBuildInputs = [ stdenv.cc.libc ];

  # Nix does not run checks; package entry points own verification.
  doCheck = false;
  dontUseZigCheck = true;

  installPhase = ''
    runHook preInstall

    # Keep Zig caches under TMPDIR, outside the source tree and separate per derivation.
    export ZIG_LOCAL_CACHE_DIR="$TMPDIR/zig-local-cache"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"

    # Keep source, compiler, platform, pkg-config, and install rules in build.zig.
    zig build install \
      --prefix "$out" \
      -j"''${NIX_BUILD_CORES:-1}" \
      -Doptimize=${optimize} \
      -Dcpu=baseline \
      ${lib.optionalString (requestedLinkage != "") "-Dlinkage=${requestedLinkage}"}

    # Drop TMPDIR rpaths (Nix forbids build-path references) but retain other paths.
    # Resolve symlinks first so patchelf updates installed objects rather than links.
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

  # zig build install owns the output layout and all installed files.

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