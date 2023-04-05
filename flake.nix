{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    haskell-flake.url = "github:srid/haskell-flake";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
    flake-root.url = "github:srid/flake-root";
    mission-control.url = "github:Platonic-Systems/mission-control";

    hasql-api.url = "github:mkleczek/hasql-api";
    hasql-transaction.url = "github:mkleczek/hasql-transaction";
    hasql-dynamic-statements.url = "github:mkleczek/hasql-dynamic-statements";
    hasql-pool.url = "github:mkleczek/hasql-pool";
    hasql-notifications.url = "github:mkleczek/hasql-notifications";
  };
  outputs = inputs@{ self, nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = builtins.filter (s: s != "mipsel-linux") nixpkgs.lib.systems.flakeExposed;
      
      imports = [
        inputs.haskell-flake.flakeModule
        inputs.treefmt-nix.flakeModule
        inputs.flake-root.flakeModule
        inputs.mission-control.flakeModule
      ];
      perSystem = { self', system, lib, config, pkgs, ... }: {

        haskellProjects.main = {
          #packages.hasql-api.root = ./.; # Auto-discovered by haskell-flake
          source-overrides = {
            hasql-api = inputs.hasql-api;
            hasql-transaction = inputs.hasql-transaction;
            hasql-dynamic-statements = inputs.hasql-dynamic-statements;
            hasql-pool = inputs.hasql-pool;
            hasql-notifications = inputs.hasql-notifications;
          };
          devShell = {
            tools = hp: {
              treefmt = config.treefmt.build.wrapper;
            } // config.treefmt.build.programs;
            hlsCheck.enable = true;
          };
        };

        # Auto formatters. This also adds a flake check to ensure that the
        # source tree was auto formatted.
        treefmt.config = {
          inherit (config.flake-root) projectRootFile;
          package = pkgs.treefmt;

          programs.ormolu.enable = true;
          programs.nixpkgs-fmt.enable = true;
          programs.cabal-fmt.enable = true;
          programs.hlint.enable = true;

          # We use fourmolu
          programs.ormolu.package = pkgs.haskellPackages.fourmolu;
          settings.formatter.ormolu = {
            options = [
              "--ghc-opt"
              "-XImportQualifiedPost"
            ];
          };
        };

        # # Dev shell scripts.
        # mission-control.scripts = {
        #   docs = {
        #     description = "Start Hoogle server for project dependencies";
        #     exec = ''
        #       echo http://127.0.0.1:8888
        #       hoogle serve -p 8888 --local
        #     '';
        #     category = "Dev Tools";
        #   };
        #   repl = {
        #     description = "Start the cabal repl";
        #     exec = ''
        #       cabal repl "$@"
        #     '';
        #     category = "Dev Tools";
        #   };
        #   fmt = {
        #     description = "Format the source tree";
        #     exec = "${lib.getExe config.treefmt.build.wrapper}";
        #     category = "Dev Tools";
        #   };
        #   run = {
        #     description = "Run the project with ghcid auto-recompile";
        #     exec = ''
        #       ghcid -c "cabal repl exe:hasql-api" --warnings -T :main
        #     '';
        #     category = "Primary";
        #   };
        # };

        # Default package.
        packages.default = self'.packages.main-postgrest;

        # Default shell.
        devShells.default = pkgs.mkShell {
          inputsFrom = [
            config.mission-control.devShell
            self'.devShells.main
          ];
        };
      };
    };
}
