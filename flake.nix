# SPDX-License-Identifier: MIT

{
  description = "Lua 5.5.1, the embeddable scripting language, packaged for Zig 0.17";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/02c087f3fe673c9e317f206a627cb6b910336dbe";
  };

  outputs = { self, nixpkgs }:
    let
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
            zig = pkgs.zig_0_17;
          };
        in
        {
          static = mk "static";

          shared = mk "dynamic";

          default = mk "static";
        });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [ pkgs.zig_0_17 pkgs.gnumake pkgs.pkg-config ];
        };
      });
    };
}