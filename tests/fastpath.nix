# Tests specific to the code region of lib/cpu.nix: halting and resuming with `step`
# and `run`, runProgram with a base that is not word-aligned, and self-modifying code
# (stores into the region must execute the new instruction, not the pre-decoded one).
let
  A = import ../lib/asm.nix;
  C = import ../lib/cpu.nix;
  D = import ../lib/dsl.nix;
  M = import ../lib/mem.nix;
  P = import ./paths.nix;
  inherit (import ../default.nix) lib;
  inherit (builtins)
    foldl'
    genList
    length
    elemAt
    div
    bitAnd
    map
    ;

  nop = A.addi 0 0 0;

  # Place instruction words at address 0.
  load =
    words:
    foldl' (m: i: M.storeWord m (i * 4) (elemAt words i)) M.empty (genList (i: i) (length words));

  # Code region covering `words` at address 0.
  regionOf = words: {
    base = 0;
    size = 4 * length words;
  };

  # Initial state at pc 0, with a code region covering `words` if withCode holds.
  start =
    withCode: words:
    C.mkState {
      mem = load words;
      code = if withCode then regionOf words else null;
    };

  pathName = withCode: if withCode then " [code region]" else "";

  # Observable outcome of a run (x1, x3 and x4 are the registers the programs use).
  outcome = s: {
    inherit (s)
      pc
      halted
      exitCode
      count
      ;
    x1 = C.getReg s 1;
    x3 = C.getReg s 3;
    x4 = C.getReg s 4;
  };

  # Run `words` from address 0 on the fast path (also compared with the slow path).
  runFast =
    words: regs:
    P.runOn "fast" {
      mem = load words;
      inherit regs;
      code = regionOf words;
      maxSteps = 1000;
    };

  # Self-modifying code: the instruction word to install and the one it replaces.
  newInst = A.addi 3 0 42;
in
map
  (withCode: {
    name = "step on a halted state clears halted and exitCode${pathName withCode}";
    got =
      let
        h = C.run { } (
          start withCode [
            A.ebreak
            (A.addi 1 0 7)
            A.ebreak
          ]
        );
        s = C.step (h // { pc = 4; });
      in
      [
        (outcome h)
        (outcome s)
        (outcome (C.run { } s))
      ];
    expected = [
      {
        pc = 0;
        halted = true;
        exitCode = -1;
        count = 1;
        x1 = 0;
        x3 = 0;
        x4 = 0;
      }
      {
        pc = 8;
        halted = false;
        exitCode = null;
        count = 2;
        x1 = 7;
        x3 = 0;
        x4 = 0;
      }
      {
        pc = 8;
        halted = true;
        exitCode = -1;
        count = 3;
        x1 = 7;
        x3 = 0;
        x4 = 0;
      }
    ];
  })
  [
    false
    true
  ]
++
  map
    (withCode: {
      name = "running a state halted by hand executes nothing${pathName withCode}";
      got =
        let
          h =
            start withCode [
              (A.addi 1 0 7)
              A.ebreak
            ]
            // {
              halted = true;
            };
        in
        [
          (outcome (C.runExactly 10 h))
          (outcome (C.run { } h))
        ];
      expected =
        let
          unchanged = {
            pc = 0;
            halted = true;
            exitCode = null;
            count = 0;
            x1 = 0;
            x3 = 0;
            x4 = 0;
          };
        in
        [
          unchanged
          unchanged
        ];
    })
    [
      false
      true
    ]
++ [
  {
    name = "runProgram with a base that is not word-aligned";
    got =
      let
        s = lib.runProgram {
          program =
            D.assemble
              {
                base = 1;
                entry = "start";
              }
              [
                (D.align 4)
                (D.label "start")
                D.ebreak
              ];
        };
      in
      {
        inherit (s) pc count halted;
      };
    expected = {
      pc = 4;
      count = 1;
      halted = true;
    };
  }
  {
    name = "runProgram with a base that is not word-aligned runs code and data";
    got =
      let
        s = lib.runProgram {
          program =
            D.assemble
              {
                base = 65538;
                entry = "start";
              }
              (
                with D;
                [
                  (label "msg")
                  (string "Z")
                  (align 4)
                  (label "start")
                  (li a0 5)
                  (la a1 "msg")
                  (lbu a2 0 a1)
                  (add a0 a0 a2)
                  ebreak
                ]
              );
        };
      in
      [
        s.halted
        s.count
        (C.getReg s D.a0)
      ];
    expected = [
      true
      6
      95 # 5 + ord "Z"
    ];
  }

  # --- Self-modifying code on the fast path ---
  {
    name = "smc: sw replaces a not-yet-executed instruction";
    got = outcome (
      runFast [
        (A.sw 0 5 12) # [12] = x5
        nop
        nop
        (A.addi 3 0 1) # 12: replaced by addi x3, x0, 42
        A.ebreak
      ] { "5" = newInst; }
    );
    expected = {
      pc = 16;
      halted = true;
      exitCode = -1;
      count = 5;
      x1 = 0;
      x3 = 42;
      x4 = 0;
    };
  }
  {
    name = "smc: two sh replace a not-yet-executed instruction";
    got = outcome (
      runFast [
        (A.sh 0 5 16) # low half of [16]
        (A.srli 6 5 16)
        (A.sh 0 6 18) # high half of [16]
        nop
        (A.addi 3 0 1) # 16: replaced by addi x3, x0, 42
        A.ebreak
      ] { "5" = newInst; }
    );
    expected = {
      pc = 20;
      halted = true;
      exitCode = -1;
      count = 6;
      x1 = 0;
      x3 = 42;
      x4 = 0;
    };
  }
  {
    name = "smc: misaligned sw replaces a not-yet-executed instruction";
    got =
      let
        old = A.addi 4 0 42;
      in
      # Only the low half differs, so the store spans the high half of the nop at 8
      # (rewritten unchanged) and the low half of the instruction at 12.
      assert div old 65536 == div newInst 65536;
      outcome (
        runFast
          [
            (A.sw 0 5 10) # bytes 10..13
            nop
            nop
            old # 12: replaced by addi x3, x0, 42
            A.ebreak
          ]
          {
            "5" = bitAnd newInst 65535 * 65536 + div nop 65536;
          }
      );
    expected = {
      pc = 16;
      halted = true;
      exitCode = -1;
      count = 5;
      x1 = 0;
      x3 = 42;
      x4 = 0;
    };
  }
  {
    name = "smc: sw replaces an instruction that already executed through a linked op";
    got = outcome (
      runFast [
        (A.addi 1 0 2) # 0: two iterations
        (A.addi 3 3 1) # 4: replaced by addi x3, x3, 100 after its first execution
        (A.sw 0 5 4) # 8
        (A.addi 1 1 (-1)) # 12
        (A.bne 1 0 (-12)) # 16: back to 4
        A.ebreak
      ] { "5" = A.addi 3 3 100; }
    );
    expected = {
      pc = 20;
      halted = true;
      exitCode = -1;
      count = 10;
      x1 = 0;
      x3 = 101;
      x4 = 0;
    };
  }
]
