{
  description = "An RV32I emulator written in pure Nix, aiming to run Doom in a terminal";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  # Upstream Doom source (an external input, like a ROM). Used only by the
  # doom-scaffold build; the emulator never reads it.
  inputs.doomgeneric = {
    url = "github:ozkl/doomgeneric";
    flake = false;
  };

  outputs =
    { nixpkgs, doomgeneric, ... }:
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
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
