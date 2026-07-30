{
  description = "collation_mf_do_you_speak_it — fast, opinionated, reproducible string collation that ignores the OS locale";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    # Pin Zig explicitly via mitchellh/zig-overlay, which exposes every
    # release as a named attr. Insulates this project from upstream nixpkgs
    # jumping Zig versions unannounced.
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        pname = "collation_mf_do_you_speak_it";
        version = "0.1.0";
        # Pinned to 0.16.0 ("Juicy Main", April 2026).
        zigPkg = zig-overlay.packages.${system}."0.16.0";
      in {
        packages.default = pkgs.stdenv.mkDerivation {
          inherit pname version;
          src = ./.;
          nativeBuildInputs = [ zigPkg ];
          dontConfigure = true;
          dontFixup = true;
          buildPhase = ''
            export HOME=$TMPDIR
            ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
            zig build -Doptimize=ReleaseFast --prefix $out
          '';
          dontInstall = true;
        };

        # NOTE: don't key on ${system} here — flake-utils.eachDefaultSystem
        # already wraps the returned attrs in ${system}. Writing
        # `checks.${system} = ...` produces checks.<sys>.<sys>, which Garnix
        # silently skips.
        checks = {
          build = self.packages.${system}.default;
          test = pkgs.stdenv.mkDerivation {
            pname = "${pname}-test";
            inherit version;
            src = ./.;
            nativeBuildInputs = [ zigPkg ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              export HOME=$TMPDIR
              ${pkgs.lib.optionalString pkgs.stdenv.isDarwin "unset NIX_CFLAGS_COMPILE NIX_LDFLAGS"}
              timeout 600 zig build test || { echo "Tests failed"; exit 1; }
            '';
            installPhase = ''
              mkdir -p $out
              echo "tests passed" > $out/result
            '';
          };
        };

        devShells.default = pkgs.mkShell {
          # coreutils `sort` (LC_ALL=C) is the differential oracle for the
          # code-point fallback integration test; `bc` is the independent
          # ARBITRARY-PRECISION oracle for the big-integer numeric tests
          # (coreutils `sort -g` loses precision past ~19 significant digits, so
          # it cannot serve); hyperfine for benchmarks; luajit generates the
          # benchmark corpus. pkg-config/gcc/icu are used ONLY by ./bm to compile
          # the ICU and glibc-strcoll comparison harnesses — NOT dependencies of
          # the library, CLI, or CI `checks`.
          nativeBuildInputs = [
            zigPkg
            pkgs.hyperfine
            pkgs.coreutils
            pkgs.bc
            pkgs.luajit
            pkgs.pkg-config
            pkgs.gcc
            pkgs.jq
          ];
          # In buildInputs so pkg-config finds icu-uc/icu-i18n on PKG_CONFIG_PATH.
          buildInputs = [ pkgs.icu ];
        };
      });
}
