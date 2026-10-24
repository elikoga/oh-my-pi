{
  description = "OMP coding agent and development environment";

  nixConfig = {
    extra-substituters = [ "https://nix-community.cachix.org" ];
    extra-trusted-public-keys = [
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # nixpkgs unstable dropped Intel macOS in 26.11; keep that supported
    # platform on the final stable branch that still receives security fixes.
    nixpkgs-darwin-x64.url = "github:NixOS/nixpkgs/nixpkgs-26.05-darwin";

    bun2nix = {
      url = "github:nix-community/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # bun2nix's per-system helper packages must use the same Intel-compatible
    # package set as the derivation consuming its overlay.
    bun2nix-darwin-x64 = {
      url = "github:nix-community/bun2nix";
      inputs.nixpkgs.follows = "nixpkgs-darwin-x64";
      inputs.systems.url = "github:nix-systems/x86_64-darwin";
    };

    nix-bun = {
      url = "github:ryoppippi/nix-bun";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      bun2nix,
      bun2nix-darwin-x64,
      nix-bun,
      nixpkgs,
      nixpkgs-darwin-x64,
      rust-overlay,
      ...
    }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # Security overlay for the 2026-10 sweep: the two fixes no nixpkgs pin
      # carries yet, both reachable from this flake's closures. The shared
      # brotli decoder sits under curl, git, node and python-brotli, and curl
      # itself is in the dev shell, so patching the attributes fixes every
      # consumer at once. Extending `pkgsFor` applies the same set to the
      # packages and the dev shells, so `nix develop` and a built `omp` agree.
      #   - google/brotli 1.2.1: CVE-2026-111497 (decoder OOB write).
      #   - curl 8.23.0: CVE-2026-92392 (HTTP/2 upload use-after-free).
      #     nixpkgs defines `curlFull` from the pre-overlay `curl`, so it needs
      #     its own re-point or it would keep the vulnerable source.
      # Hashes are the ones verified against the upstream release digests in
      # the fleet overlay (elikoga-nixos overlays/security-2026-10.nix).
      # Remove this once a channel carries both versions.
      securityOverlay =
        final: prev:
        let
          bumpCurl =
            pkg:
            pkg.overrideAttrs (_: {
              version = "8.23.0";
              src = final.fetchurl {
                urls = [
                  "https://curl.se/download/curl-8.23.0.tar.xz"
                  "https://github.com/curl/curl/releases/download/curl-8_23_0/curl-8.23.0.tar.xz"
                ];
                hash = "sha256-ja3X0lNqMU+YKtBaZRtxP0Jr99Aswsds/7l5byIY5sU=";
              };
            });
        in
        {
          brotli = prev.brotli.overrideAttrs (_: {
            version = "1.2.1";
            src = final.fetchFromGitHub {
              owner = "google";
              repo = "brotli";
              tag = "v1.2.1";
              hash = "sha256-llY72cYffDv0ugsH0p89xIPEbElV4L8u7U/Fe8hT3gI=";
            };
          });
          curl = bumpCurl prev.curl;
          curlFull = bumpCurl prev.curlFull;
        };

      pkgsFor =
        system:
        (if system == "x86_64-darwin" then nixpkgs-darwin-x64 else nixpkgs).legacyPackages.${system}.extend
          securityOverlay;

      bun2nixFor =
        system:
        (if system == "x86_64-darwin" then bun2nix-darwin-x64 else bun2nix).packages.${system}.bun2nix;

      rustToolchainFor =
        system:
        (rust-overlay.lib.mkRustBin { } (pkgsFor system)).fromRustupToolchainFile ./rust-toolchain.toml;

      localPackagesFor =
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          bun = pkgs.callPackage (nix-bun.outPath + "/package.nix") {
            sourcesFile = nix-bun.outPath + "/versions/1.4.4.json";
          };
          bun2nix = bun2nixFor system;
          rustToolchain = rustToolchainFor system;
        };

      packageFor =
        system:
        let
          pkgs = pkgsFor system;
          localPkgs = localPackagesFor system;
        in
        pkgs.callPackage ./nix/package.nix (
          {
            source = self.outPath;
          }
          // localPkgs
        );
    in
    {
      packages = forAllSystems (
        system:
        let
          omp = packageFor system;
        in
        {
          inherit omp;
          default = omp;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/omp";
          meta.description = "Run OMP";
        };
        omp = self.apps.${system}.default;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          localPackages = localPackagesFor system;
        in
        {
          default = import ./nix/dev-shell.nix ({ inherit pkgs; } // localPackages);
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          bun2nix = bun2nixFor system;
          homeManagerEvaluation = pkgs.lib.evalModules {
            specialArgs = { inherit pkgs; };
            modules = [
              {
                options.home.packages = pkgs.lib.mkOption {
                  type = pkgs.lib.types.listOf pkgs.lib.types.package;
                  default = [ ];
                };
                options.home.activation = pkgs.lib.mkOption {
                  type = pkgs.lib.types.attrsOf pkgs.lib.types.anything;
                  default = { };
                };
              }
              self.homeManagerModules.default
              {
                programs.omp.enable = true;
                programs.omp.settings.startup.quiet = true;
              }
            ];
          };
          nixosEvaluation = pkgs.lib.evalModules {
            specialArgs = { inherit pkgs; };
            modules = [
              {
                options.environment.systemPackages = pkgs.lib.mkOption {
                  type = pkgs.lib.types.listOf pkgs.lib.types.package;
                  default = [ ];
                };
              }
              self.nixosModules.default
              { programs.omp.enable = true; }
            ];
          };
          modulesEvaluate =
            assert builtins.elem self.packages.${system}.default homeManagerEvaluation.config.home.packages;
            assert homeManagerEvaluation.config.home.activation ? ompConfig;
            assert builtins.elem self.packages.${system}.default
              nixosEvaluation.config.environment.systemPackages;
            pkgs.runCommand "omp-module-evaluation" { } "touch $out";
        in
        {
          bun-lock = pkgs.runCommand "omp-bun-lock" { nativeBuildInputs = [ bun2nix ]; } ''
            cp -R ${self.outPath} source
            chmod -R u+w source
            cd source
            mv nix/bun.nix nix/bun.expected.nix
            bun2nix -l bun.lock -c ../ -o nix/bun.nix
            sed -i -e '$a\' nix/bun.nix
            diff -u nix/bun.expected.nix nix/bun.nix
            touch "$out"
          '';
          modules = modulesEvaluate;
          omp = self.packages.${system}.default;
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);

      overlays.default = _final: previous: {
        omp = self.packages.${previous.stdenv.hostPlatform.system}.default;
      };

      homeManagerModules.default = import ./nix/home-manager.nix { inherit self; };
      homeManagerModules.omp = self.homeManagerModules.default;
      nixosModules.default = import ./nix/nixos-module.nix { inherit self; };
      nixosModules.omp = self.nixosModules.default;
    };
}
