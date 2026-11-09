# Unit tests: per-instruction RV32I tests below, plus eDSL tests from tests/dsl.nix,
# M extension tests from tests/mext.nix, Doom extension tests from tests/xdoom.nix and
# code-region tests from tests/fastpath.nix.
# Run: nix eval --json -f tests/unit.nix summary
# Each test places a small machine-code sequence at address 0, runs it until the trailing
# EBREAK halts, and compares registers, memory and PC against expected values. Every CPU
# test runs both without and with a code region (see tests/paths.nix).
let
  A = import ../lib/asm.nix;
  B = import ../lib/bits.nix;
  C = import ../lib/cpu.nix;
  M = import ../lib/mem.nix;
  P = import ./paths.nix;
  inherit (builtins)
    foldl'
    genList
    length
    elemAt
    filter
    map
    toString
    attrNames
    ;

  u = x: B.u32 x;

  # Place a program in memory (an EBREAK is appended automatically).
  loadProgram =
    mem: code:
    let
      words = code ++ [ A.ebreak ];
    in
    foldl' (m: i: M.storeWord m (i * 4) (elemAt words i)) mem (genList (i: i) (length words));

  # Run a program with `run` (see tests/paths.nix); the code region covers the program
  # and its EBREAK. regs: initial register values { "5" = ...; }, data: initial memory
  # [ { addr; value; } ]
  execWith =
    run:
    {
      code,
      regs ? { },
      data ? [ ],
    }:
    let
      mem0 = foldl' (m: d: M.storeWord m d.addr d.value) M.empty data;
    in
    run {
      mem = loadProgram mem0 code;
      regs = builtins.mapAttrs (_: u) regs;
      code = {
        base = 0;
        size = 4 * (length code + 1);
      };
      maxSteps = 1000;
    };

  reg = s: i: C.getReg s i;

  # Tests that execute instructions, as a function of the runner.
  cpuCases =
    run:
    let
      exec = execWith run;

      # Boilerplate test: execute one instruction and check rd (x3).
      alu1 = name: inst: a: b: expected: {
        inherit name;
        got = reg (exec {
          code = [ inst ];
          regs = {
            "1" = a;
            "2" = b;
          };
        }) 3;
        expected = u expected;
      };
    in
    [
      # --- OP (register-register) ---
      (alu1 "add" (A.add 3 1 2) 5 7 12)
      (alu1 "add overflow wraps" (A.add 3 1 2) 4294967295 2 1)
      (alu1 "sub" (A.sub 3 1 2) 5 7 (-2))
      (alu1 "sll" (A.sll 3 1 2) 1 31 2147483648)
      (alu1 "sll uses low 5 bits" (A.sll 3 1 2) 1 33 2)
      (alu1 "slt true" (A.slt 3 1 2) (-1) 1 1)
      (alu1 "slt false" (A.slt 3 1 2) 1 (-1) 0)
      (alu1 "sltu" (A.sltu 3 1 2) 1 (-1) 1)
      (alu1 "xor" (A.xor 3 1 2) 12 10 6)
      (alu1 "srl" (A.srl 3 1 2) (-16) 4 268435455)
      (alu1 "sra negative" (A.sra 3 1 2) (-16) 2 (-4))
      (alu1 "sra -1 stays -1" (A.sra 3 1 2) (-1) 31 (-1))
      (alu1 "sra positive" (A.sra 3 1 2) 64 3 8)
      (alu1 "or" (A.or 3 1 2) 12 10 14)
      (alu1 "and" (A.and 3 1 2) 12 10 8)

      # --- OP-IMM ---
      (alu1 "addi" (A.addi 3 1 (-1)) 10 0 9)
      (alu1 "addi min imm" (A.addi 3 1 (-2048)) 0 0 (-2048))
      (alu1 "slti" (A.slti 3 1 (-1)) (-5) 0 1)
      (alu1 "sltiu sext imm" (A.sltiu 3 1 (-1)) 5 0 1)
      (alu1 "xori -1 is not" (A.xori 3 1 (-1)) 0 0 (-1))
      (alu1 "ori" (A.ori 3 1 255) 256 0 511)
      (alu1 "andi" (A.andi 3 1 15) 255 0 15)
      (alu1 "slli" (A.slli 3 1 4) 3 0 48)
      (alu1 "srli" (A.srli 3 1 28) (-1) 0 15)
      (alu1 "srai" (A.srai 3 1 28) (-2147483648) 0 (-8))

      # --- U-type ---
      (alu1 "lui" (A.lui 3 (-4096)) 0 0 (-4096))
      {
        name = "auipc";
        got = reg (exec {
          code = [
            A.fence
            (A.auipc 3 4096)
          ];
        }) 3;
        expected = 4100;
      }

      # --- x0 is always zero ---
      {
        name = "write to x0 ignored";
        got = reg (exec { code = [ (A.addi 0 0 5) ]; }) 0;
        expected = 0;
      }

      # --- Jumps ---
      {
        name = "jal link and target";
        got =
          let
            s = exec {
              code = [
                (A.jal 1 8)
                (A.addi 3 0 1) # skipped
                (A.addi 4 0 2)
              ];
            };
          in
          [
            (reg s 1)
            (reg s 3)
            (reg s 4)
          ];
        expected = [
          4
          0
          2
        ];
      }
      {
        name = "jal backward";
        got =
          let
            s = exec {
              code = [
                (A.jal 0 12) # 0 -> 12
                (A.addi 3 3 1) # 4: landing spot of the backward jump
                (A.jal 0 12) # 8 -> 20
                (A.jal 0 (-8)) # 12 -> 4
                (A.addi 3 3 100) # 16: skipped
              ];
            };
          in
          reg s 3;
        expected = 1;
      }
      {
        name = "jalr clears lsb and links";
        got =
          let
            s = exec {
              code = [
                (A.jalr 1 5 1) # x5=8 -> 9 & ~1 = 8
                (A.addi 3 0 1)
                (A.addi 4 0 2)
              ];
              regs."5" = 8;
            };
          in
          [
            (reg s 1)
            (reg s 3)
            (reg s 4)
          ];
        expected = [
          4
          0
          2
        ];
      }

      # --- Branches (when taken, the addi to x3 is skipped) ---
    ]
    ++
      map
        (
          t:
          let
            s = exec {
              code = [
                (t.inst 1 2 8)
                (A.addi 3 0 1)
              ];
              regs = {
                "1" = t.a;
                "2" = t.b;
              };
            };
          in
          {
            name = "branch ${t.n}";
            got = reg s 3;
            expected = if t.taken then 0 else 1;
          }
        )
        [
          {
            n = "beq taken";
            inst = A.beq;
            a = 3;
            b = 3;
            taken = true;
          }
          {
            n = "beq not";
            inst = A.beq;
            a = 3;
            b = 4;
            taken = false;
          }
          {
            n = "bne taken";
            inst = A.bne;
            a = 3;
            b = 4;
            taken = true;
          }
          {
            n = "blt signed";
            inst = A.blt;
            a = -1;
            b = 1;
            taken = true;
          }
          {
            n = "bge signed";
            inst = A.bge;
            a = -1;
            b = 1;
            taken = false;
          }
          {
            n = "bge equal";
            inst = A.bge;
            a = 7;
            b = 7;
            taken = true;
          }
          {
            n = "bltu unsigned";
            inst = A.bltu;
            a = -1;
            b = 1;
            taken = false;
          }
          {
            n = "bgeu unsigned";
            inst = A.bgeu;
            a = -1;
            b = 1;
            taken = true;
          }
        ]
    ++ [
      {
        name = "branch backward loop (sum 1..10)";
        got =
          let
            s = exec {
              code = [
                (A.addi 1 0 10) # 0: i = 10
                (A.add 3 3 1) # 4: acc += i
                (A.addi 1 1 (-1)) # 8: i--
                (A.bne 1 0 (-8)) # 12: go to 4 while i != 0
              ];
            };
          in
          reg s 3;
        expected = 55;
      }

      # --- Loads / stores ---
      {
        name = "lw/lb/lbu/lh/lhu";
        got =
          let
            s = exec {
              code = [
                (A.lw 3 1 0)
                (A.lb 4 1 3)
                (A.lbu 5 1 3)
                (A.lh 6 1 2)
                (A.lhu 7 1 2)
                (A.lb 8 1 0)
              ];
              regs."1" = 256;
              data = [
                {
                  addr = 256;
                  value = 2165056375; # 0x810c_2377
                }
              ];
            };
          in
          map (reg s) [
            3
            4
            5
            6
            7
            8
          ];
        expected = map u [
          2165056375
          (-127) # 0x81 sign-extended
          129
          (-32500) # 0x810c sign-extended
          33036
          119 # 0x77
        ];
      }
      {
        name = "load with negative offset";
        got = reg (exec {
          code = [ (A.lw 3 1 (-4)) ];
          regs."1" = 260;
          data = [
            {
              addr = 256;
              value = 42;
            }
          ];
        }) 3;
        expected = 42;
      }
      {
        name = "sb/sh/sw then lw";
        got =
          let
            s = exec {
              code = [
                (A.sw 1 2 0) # [256] = 0x11223344
                (A.sb 1 3 1) # byte1 = 0xAA
                (A.sh 1 4 2) # half1 = 0xBEEF
                (A.lw 5 1 0)
                (A.sw 1 2 (-4)) # negative S-type immediate
                (A.lw 6 1 (-4))
              ];
              regs = {
                "1" = 256;
                "2" = 287454020;
                "3" = 170;
                "4" = 48879;
              };
            };
          in
          [
            (reg s 5)
            (reg s 6)
          ];
        expected = [
          3203377732 # 0xBEEF_AA44
          287454020
        ];
      }
      {
        name = "misaligned word access";
        got =
          let
            s = exec {
              code = [
                (A.sw 1 2 1)
                (A.lw 3 1 1)
                (A.lbu 4 1 4)
              ];
              regs = {
                "1" = 256;
                "2" = 3735928559; # 0xDEADBEEF
              };
            };
          in
          [
            (reg s 3)
            (reg s 4)
          ];
        expected = [
          3735928559
          222 # 0xDE lands at address 260
        ];
      }
      # --- SYSTEM ---
      {
        name = "ecall write + exit";
        got =
          let
            s = exec {
              code = [
                (A.addi 17 0 64) # write
                (A.addi 10 0 1)
                (A.addi 11 0 256)
                (A.addi 12 0 3)
                A.ecall
                (A.addi 17 0 93) # exit(7)
                (A.addi 10 0 7)
                A.ecall
              ];
              data = [
                {
                  addr = 256;
                  value = 663913; # "i!\n"
                }
              ];
            };
          in
          {
            inherit (s) out exitCode halted;
          };
        expected = {
          out = "i!\n";
          exitCode = 7;
          halted = true;
        };
      }
      {
        name = "ebreak halts and counts";
        got =
          let
            s = exec { code = [ A.fence ]; };
          in
          [
            s.halted
            s.count
            s.pc
          ];
        expected = [
          true
          2
          4
        ];
      }
    ];

  cases =
    P.bothPaths cpuCases
    ++ [
      {
        name = "memory tree: sparse high address";
        got =
          let
            m = M.storeWord (M.storeWord M.empty 4294967292 7) 0 9;
          in
          [
            (M.loadWord m 4294967292)
            (M.loadWord m 0)
            (M.loadWord m 1048576)
          ];
        expected = [
          7
          9
          0
        ];
      }
    ]
    ++ import ./dsl.nix
    ++ import ./mext.nix
    ++ import ./xdoom.nix
    ++ import ./fastpath.nix;

  failures = filter (t: t.got != t.expected) cases;
in
{
  summary = {
    total = length cases;
    failed = map (t: {
      inherit (t) name got expected;
    }) failures;
  };
  # Fail evaluation if any test fails (for CI).
  check =
    if failures == [ ] then
      "ok: ${toString (length cases)} tests passed"
    else
      throw "unit tests failed: ${toString (map (t: t.name) failures)}";
}
