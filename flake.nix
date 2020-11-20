{
  description = "NixOps: a tool for deploying to [NixOS](https://nixos.org) machines in a network or the cloud";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-20.09";

  inputs.utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, utils }: utils.lib.eachDefaultSystem (system: let
    pkgs = import nixpkgs { inherit system; };

    poetry2nix = import (pkgs.fetchFromGitHub {
      owner = "nix-community";
      repo = "poetry2nix";
      rev = "1894b501cf4431fb218c4939a9acdbf397ac1803";
      sha256 = "13ldn2gcqc3glzshxyxz9pz6gr53y8zgabgx42pcszwhrkvfk9l8";
    }) { inherit pkgs; inherit (pkgs) poetry; };

    pythonEnv = (poetry2nix.mkPoetryEnv {
      projectDir = ./.;
    });
    linters.doc = pkgs.writers.writeBashBin "lint-docs" ''
      set -eux
      # When running it in the Nix sandbox, there is no git repository
      # but sources are filtered.
      if [ -d .git ];
      then
          FILES=$(${pkgs.git}/bin/git ls-files)
      else
          FILES=$(find .)
      fi
      echo "$FILES" | xargs ${pkgs.codespell}/bin/codespell -L keypair,iam,hda
      ${pythonEnv}/bin/sphinx-build -M clean doc/ doc/_build
      ${pythonEnv}/bin/sphinx-build -n doc/ doc/_build
      '';

  in {
    devShell = pkgs.mkShell {
      buildInputs = [
        pythonEnv
        pkgs.openssh
        pkgs.poetry
        pkgs.rsync  # Included by default on NixOS
        pkgs.nixFlakes
        pkgs.codespell
      ] ++ (builtins.attrValues linters);

      shellHook = ''
        export PATH=${builtins.toString ./scripts}:$PATH
      '';
    };

    defaultPackage = let
      overrides = import ./overrides.nix { inherit pkgs; };

    in poetry2nix.mkPoetryApplication {
      projectDir = ./.;

      propagatedBuildInputs = [
        pkgs.openssh
        pkgs.rsync
      ];

      overrides = [
        poetry2nix.defaultPoetryOverrides
        overrides
      ];

      # TODO: Re-add manual build
    };

    nixosOptions = pkgs.nixosOptionsDoc {
      inherit (pkgs.lib.fixMergeModules [ ./nix/options.nix ] {
        inherit pkgs;
        name = "<name>";
        uuid = "<uuid>";
      }) options;
    };

    rstNixosOptions = let
      oneRstOption = name: value: ''
        ${name}
        ${pkgs.lib.concatStrings (builtins.genList (_: "-") (builtins.stringLength name))}

        ${value.description}

        ${pkgs.lib.optionalString (value ? readOnly) ''
          Read Only
        ''}

        :Type: ${value.type}

        ${pkgs.lib.optionalString (value ? default) ''
          :Default: ${builtins.toJSON value.default}
        ''}

        ${pkgs.lib.optionalString (value ? example) ''
          :Example: ${builtins.toJSON value.example}
        ''}
      '';
      text = ''
        NixOps Options
        ==============
      '' + pkgs.lib.concatStringsSep "\n" (pkgs.lib.mapAttrsToList oneRstOption self.nixosOptions.${pkgs.system}.optionsNix);
    in pkgs.writeText "options.rst" text;

    docs = pkgs.stdenv.mkDerivation {
      name = "nixops-docs";
      # we use cleanPythonSources because the default gitignore
      # implementation doesn't support the restricted evaluation
      src = poetry2nix.cleanPythonSources {
        src = ./.;
      };

      buildPhase = ''
        cp ${self.rstNixosOptions.${pkgs.system}} doc/manual/options.rst
        ${pythonEnv}/bin/sphinx-build -M clean doc/ doc/_build
        ${pythonEnv}/bin/sphinx-build -n doc/ doc/_build
      '';

      installPhase = ''
        mv doc/_build $out
      '';
    };

    checks.doc = pkgs.stdenv.mkDerivation {
      name = "lint-docs";
      # we use cleanPythonSources because the default gitignore
      # implementation doesn't support the restricted evaluation
      src = poetry2nix.cleanPythonSources {
        src = ./.;
      };
      dontBuild = true;
      installPhase = ''
        ${linters.doc}/bin/lint-docs | tee $out
      '';
    };
  });
}
