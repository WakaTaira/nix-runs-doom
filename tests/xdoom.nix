# Tests for the Doom extension instructions (custom-0). Each case group is a function
# of the runner (see tests/paths.nix) returning a list of tests; add new groups to
# `groups`. Every case runs both without and with a code region.
let
  A = import ../lib/asm.nix;
  B = import ../lib/bits.nix;
  C = import ../lib/cpu.nix;
  M = import ../lib/mem.nix;
  P = import ./paths.nix;
  inherit (builtins) concatMap;

  # FIXMUL: x3 = fixmul(x1, x2), with x1 = a and x2 = b given as signed or unsigned
  # integers and the expected value normalized to the unsigned 32-bit form.
  fixmulCases =
    run:
    let
      exec =
        a: b:
        run {
          mem = M.storeWord (M.storeWord M.empty 0 (A.fixmul 3 1 2)) 4 A.ebreak;
          regs = {
            "1" = B.u32 a;
            "2" = B.u32 b;
          };
          code = {
            base = 0;
            size = 8;
          };
          maxSteps = 10;
        };

      op = name: a: b: expected: {
        name = "xdoom: fixmul ${name}";
        got = C.getReg (exec a b) 3;
        expected = B.u32 expected;
      };
    in
    [
      (op "3.0 * 2.0" 196608 131072 393216)
      (op "-3.0 * 2.0" (-196608) 131072 (-393216))
      (op "-1 * 1 floors to -1" 4294967295 1 4294967295)
      (op "INT_MAX * INT_MAX" 2147483647 2147483647 4294901760) # (0x7FFFFFFF^2 >> 16) mod 2^32
    ];

  groups = [ fixmulCases ];
in
P.bothPaths (run: concatMap (g: g run) groups)
