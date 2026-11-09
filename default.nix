# Entry point (works with `nix eval -f . <attr>` and, via flake.nix, `.#<attr>`).
#   nix eval --raw -f . fizzbuzz.stdout     # FizzBuzz (Nix eDSL guest) standard output
#   nix eval --json -f . fizzbuzz.stats     # executed instruction count and exit code
#   nix eval --raw -f . tests.check         # unit tests
#   nix eval --raw -f . bench.report        # performance budget (see bench/default.nix)
let
  C = import ./lib/cpu.nix;
  E = import ./lib/elf.nix;
  D = import ./lib/dsl.nix;
  M = import ./lib/mem.nix;

  # Run an assembled eDSL program and return the halted state.
  runProgram =
    {
      program,
      maxSteps ? 100000000,
    }:
    C.run { inherit maxSteps; } (
      C.mkState {
        mem = D.toMemory M.empty program;
        pc = program.entry;
      }
    );

  # Load a hex-encoded ELF, run it, and return the halted state.
  runElfHex =
    {
      hexFile,
      maxSteps ? 100000000,
      sp ? 0,
    }:
    let
      img = E.load (builtins.readFile hexFile);
      s0 = C.mkState {
        inherit (img) mem;
        pc = img.entry;
        inherit sp;
      };
    in
    C.run { inherit maxSteps; } s0;

  report = s: {
    stdout = s.out;
    stats = {
      inherit (s) exitCode halted;
      instructions = s.count;
    };
  };
in
{
  lib = {
    bits = import ./lib/bits.nix;
    mem = M;
    cpu = C;
    elf = E;
    asm = import ./lib/asm.nix;
    dsl = D;
    inherit runProgram runElfHex;
  };

  tests = import ./tests/unit.nix;

  fizzbuzz = report (runProgram {
    program = import ./examples/fizzbuzz { };
  });

  # Transitional: the clang-built C version, for comparison only.
  fizzbuzzC = report (runElfHex {
    hexFile = ./examples/fizzbuzz-c/fizzbuzz.hex;
  });

  bench = import ./bench;
}
