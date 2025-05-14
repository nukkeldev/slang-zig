{
  description = "The Slang Shading Language and Compiler";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        formatter = pkgs.nixfmt-rfc-style;

        devShell =
          with pkgs;
          mkShell {
            buildInputs = [
              cmake
              llvm
              ninja
              python3
              xorg.libX11

              # zig
              zls
              zig_0_14
            ];
          };
      }
    );
}
