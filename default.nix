let
  nixpkgs = builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/ac6b2166e7a9375683b8e98f860f273222337b16.tar.gz";
    sha256 = "0k6m5apwzg36qkm3wil1pf4q0lv1hp7r2imx4nfz9bfssnk9gj5w";
  };
  pkgs = import nixpkgs { };
  source = pkgs.lib.cleanSourceWith {
    src = ./.;
    filter = path: type:
      pkgs.lib.cleanSourceFilter path type
      && !(builtins.elem (builtins.baseNameOf path) [
        "dist-newstyle"
        "cabal.project.local"
      ]);
  };
in
pkgs.haskell.packages.ghc9141.callCabal2nix "geometry-simple" source { }
