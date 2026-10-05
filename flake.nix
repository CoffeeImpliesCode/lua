# Flake interface for the Lua SDK.
#
# Portable counterpart to devenv.nix. Both call ./package.nix, so the package a
# flake builds and the package devenv builds are the same derivation; this file
# only decides which systems are exposed and which variants of that derivation
# they get.
#
# Canonical development is `devenv shell` (see devenv.nix and .envrc). This
# flake exists so the SDK can be built and consumed off this host. `nix develop`
# here is parity, not the canonical entry point, and it deliberately does not
# build the SDK: entering a shell must not require building a library.
#
# flake.lock is not written here: the driver owns locks.
#
# SPDX-License-Identifier: MIT

{
  description = "Lua 5.5.1, the embeddable scripting language, packaged for Zig 0.16";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/c7def046b9a883d46974757852106483d741586f";
  };

  outputs = { self, nixpkgs }:
    let
      # Lua's own Makefile builds an archive and installs no shared object, so
      # the SDK's native policy is static and `.default` stays that way. These
      # are Unix systems only, which is the same boundary package.nix asserts:
      # it builds for the compiler's native target rather than hand-building a
      # cross triple. Documented in README.md, not worked around here.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
        "x86_64-freebsd"
      ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs:
        let
          mk = linkage: pkgs.callPackage ./package.nix {
            inherit linkage;
            zig = pkgs.zig_0_16;
          };
        in
        {
          static = mk "static";

          # A separate variant of the same derivation, not a second SDK.
          # "shared" names the artefact; the flag it passes is Zig's own
          # `-Dlinkage=dynamic`.
          shared = mk "dynamic";

          default = mk "static";
        });

      # Parity only. The canonical development environment is devenv.nix.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.zig_0_16 pkgs.gnumake pkgs.pkg-config ];
        };
      });
    };
}