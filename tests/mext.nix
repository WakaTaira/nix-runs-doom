# Tests for the M extension (multiply/divide). Each case runs one instruction
# x3 = op(x1, x2) and checks x3. Expected values are given as signed or unsigned
# integers and normalized to the unsigned 32-bit form. Every case runs both without
# and with a code region (see tests/paths.nix).
let
  A = import ../lib/asm.nix;
  B = import ../lib/bits.nix;
  C = import ../lib/cpu.nix;
  D = import ../lib/dsl.nix;
  M = import ../lib/mem.nix;
  P = import ./paths.nix;

  intMin = -2147483648;
in
P.bothPaths (
  run:
  let
    # Run `inst` followed by EBREAK with x1 = a and x2 = b, and return the final state.
    exec =
      inst: a: b:
      run {
        mem = M.storeWord (M.storeWord M.empty 0 inst) 4 A.ebreak;
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

    op = name: inst: a: b: expected: {
      name = "mext: ${name}";
      got = C.getReg (exec (inst 3 1 2) a b) 3;
      expected = B.u32 expected;
    };
  in
  [
    # --- MUL (low word) ---
    (op "mul small" A.mul 6 7 42)
    (op "mul negative" A.mul (-3) 5 (-15))
    (op "mul 0xFFFFFFFF * 0xFFFFFFFF low" A.mul 4294967295 4294967295 1)
    (op "mul large operands low" A.mul 305419896 2596069104 606937216) # 0x12345678 * 0x9ABCDEF0
    (op "mul signed mixed low" A.mul (-123456789) 987654321 67153019)

    # --- MULHU ---
    (op "mulhu 0xFFFFFFFF * 0xFFFFFFFF" A.mulhu 4294967295 4294967295 4294967294)
    (op "mulhu large operands" A.mulhu 305419896 2596069104 184609358)
    (op "mulhu small product is 0" A.mulhu 65535 65535 0)

    # --- MULH (signed x signed) ---
    (op "mulh -1 * -1" A.mulh (-1) (-1) 0)
    (op "mulh INT_MIN * INT_MIN" A.mulh intMin intMin 1073741824)
    (op "mulh -2 * 3" A.mulh (-2) 3 (-1))
    (op "mulh INT_MAX * INT_MAX" A.mulh 2147483647 2147483647 1073741823)
    (op "mulh signed mixed" A.mulh (-123456789) 987654321 4266577643)

    # --- MULHSU (rs1 signed, rs2 unsigned) ---
    (op "mulhsu -1 * 0xFFFFFFFF" A.mulhsu (-1) 4294967295 (-1))
    (op "mulhsu INT_MIN * 0xFFFFFFFF" A.mulhsu intMin 4294967295 intMin)
    (op "mulhsu 5 * 0xFFFFFFFF" A.mulhsu 5 4294967295 4)

    # --- DIV / REM (signed, round toward zero, remainder follows the dividend) ---
    (op "div 20 / 3" A.div 20 3 6)
    (op "div -20 / 3" A.div (-20) 3 (-6))
    (op "div 20 / -3" A.div 20 (-3) (-6))
    (op "div -20 / -3" A.div (-20) (-3) 6)
    (op "rem 20 % 3" A.rem 20 3 2)
    (op "rem -20 % 3" A.rem (-20) 3 (-2))
    (op "rem 20 % -3" A.rem 20 (-3) 2)
    (op "rem -20 % -3" A.rem (-20) (-3) (-2))

    # --- DIVU / REMU ---
    (op "divu 0xFFFFFFFF / 2" A.divu 4294967295 2 2147483647)
    (op "divu -20 as unsigned / 3" A.divu (-20) 3 1431655758)
    (op "remu 0xFFFFFFFF % 10" A.remu 4294967295 10 5)

    # --- Division by zero ---
    (op "div by zero" A.div 7 0 (-1))
    (op "divu by zero" A.divu 7 0 4294967295)
    (op "rem by zero" A.rem (-7) 0 (-7))
    (op "remu by zero" A.remu 4294967295 0 4294967295)

    # --- Signed overflow ---
    (op "div INT_MIN / -1" A.div intMin (-1) intMin)
    (op "rem INT_MIN / -1" A.rem intMin (-1) 0)

    # --- eDSL items ---
    {
      name = "mext: dsl items (10! / 11 and 10! % 11 via mul/divu/remu)";
      got =
        let
          prog = D.assemble { } (
            with D;
            [
              (li a0 1)
              (li a1 10)
              (label "loop")
              (mul a0 a0 a1)
              (addi a1 a1 (-1))
              (bnez a1 "loop")
              (li a2 11)
              (divu a3 a0 a2)
              (remu a4 a0 a2)
              ebreak
            ]
          );
          s = run {
            mem = D.toMemory M.empty prog;
            pc = prog.entry;
            code = {
              inherit (prog) base size;
            };
            maxSteps = 1000;
          };
        in
        map (C.getReg s) [
          D.a0
          D.a3
          D.a4
        ];
      expected = [
        3628800
        329890
        10
      ];
    }
  ]
)
