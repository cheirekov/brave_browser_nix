{
  description = "br: Brave built from source without Tor support";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/master";

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      overlay = final: _prev: {
        br = final.callPackage ./package.nix { };
      };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ overlay ];
          };
        in
        {
          inherit (pkgs) br;
          default = pkgs.br;
        }
      );

      overlays.default = overlay;

      nixosModules.default = import ./nix/module.nix { inherit self; };

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          package = self.packages.${system}.br;
          sourceMetadata = builtins.fromJSON (builtins.readFile ./nix/sources.json);
        in
        {
          source-policy =
            pkgs.runCommand "br-source-policy"
              {
                nativeBuildInputs = [
                  pkgs.bash
                  pkgs.jq
                ];
              }
              ''
                ${pkgs.bash}/bin/bash ${./scripts/verify.sh} --source ${self}
                touch "$out"
              '';

          package-evaluation = pkgs.runCommand "br-package-evaluation" { } ''
            test ${nixpkgs.lib.escapeShellArg package.pname} = br
            test ${nixpkgs.lib.escapeShellArg package.version} = \
              ${nixpkgs.lib.escapeShellArg sourceMetadata.version}
            touch "$out"
          '';
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-tree);
    };
}
