{
  description = "Doom in a terminal by nix eval alone: a C compiler and an RV32IM emulator written in pure Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Upstream Doom source (an external input, like a ROM). The evaluation takes its path
  # from DOOM_SRC (see doom/default.nix); the launcher and the doom-scaffold build pass it.
  inputs.doomgeneric = {
    url = "github:ozkl/doomgeneric";
    flake = false;
  };

  outputs =
    {
      self,
      nixpkgs,
      doomgeneric,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The emulator and its guests are system-independent pure Nix.
      # (bench reads an environment variable, so use `nix eval -f . bench.*` for it.)
      emulator = import ./default.nix;
    in
    {
      inherit (emulator)
        lib
        tests
        fizzbuzz
        fizzbuzzC
        ;

      # Transitional: the clang-built C FizzBuzz, used only to regenerate
      # examples/fizzbuzz-c/fizzbuzz.hex. Removed once every guest is Nix.
      packages = forAllSystems (pkgs: {
        fizzbuzz-c = import ./examples/fizzbuzz-c {
          buildGuest = import ./toolchain/guest.nix { inherit pkgs; };
        };

        # The clang-built doomgeneric scaffold; evaluation reads its doom.hex from
        # `nix build .#doom-scaffold -o result-doom`.
        doom-scaffold = import ./toolchain/doom.nix { inherit pkgs doomgeneric; };

        # The launcher of `nix run .#play` (the app below).
        play = import ./toolchain/play.nix { inherit pkgs doomgeneric self; };
      });

      # The launcher of `nix run .#play -- /path/to/doom1.wad` (see toolchain/play.nix): it
      # only connects the terminal to `nix eval -f . doom.play`.
      apps = forAllSystems (
        pkgs:
        let
          play = {
            type = "app";
            program = pkgs.lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.play;
          };
        in
        {
          inherit play;
          default = play;
        }
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
