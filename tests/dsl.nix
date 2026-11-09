# Tests for the Nix eDSL (lib/dsl.nix): pseudo-instruction expansion, label
# resolution, structured control flow and data directives. Each case assembles
# a program, runs it to EBREAK, and checks registers or memory.
let
  D = import ../lib/dsl.nix;
  B = import ../lib/bits.nix;
  C = import ../lib/cpu.nix;
  M = import ../lib/mem.nix;

  run =
    program:
    let
      prog = D.assemble { } [
        program
        D.ebreak
      ];
    in
    C.run { maxSteps = 10000; } (
      C.mkState {
        mem = D.toMemory M.empty prog;
        pc = prog.entry;
      }
    );

  regOf = s: r: C.getReg s r;
in
with D;
[
  {
    name = "dsl: li small, 0x800 boundary, large and negative";
    got =
      let
        s = run [
          (li a0 2047)
          (li a1 2048)
          (li a2 305419896) # 0x12345678
          (li a3 (-1))
          (li a4 (-305419896))
          (li a5 4294965248) # 0xFFFFF800
        ];
      in
      map (regOf s) [
        a0
        a1
        a2
        a3
        a4
        a5
      ];
    expected = map B.u32 [
      2047
      2048
      305419896
      (-1)
      (-305419896)
      4294965248
    ];
  }
  {
    name = "dsl: forward and backward labels";
    got =
      let
        s = run [
          (li t0 3)
          (label "top")
          (addi a0 a0 10)
          (addi t0 t0 (-1))
          (bnez t0 "top")
          (j "end")
          (addi a0 a0 1000) # skipped
          (label "end")
        ];
      in
      regOf s a0;
    expected = 30;
  }
  {
    name = "dsl: when / ifElse";
    got =
      let
        s = run [
          (li t0 1)
          (when (eq t0 zero) [ (li a0 1) ])
          (when (ne t0 zero) [ (li a1 1) ])
          (ifElse (lt t0 zero) [ (li a2 1) ] [ (li a2 2) ])
          (ifElse (ge t0 zero) [ (li a3 1) ] [ (li a3 2) ])
        ];
      in
      map (regOf s) [
        a0
        a1
        a2
        a3
      ];
    expected = [
      0
      1
      2
      1
    ];
  }
  {
    name = "dsl: while sums 1..10";
    got =
      let
        s = run [
          (li t0 1)
          (li t1 11)
          (while (ltu t0 t1) [
            (add a0 a0 t0)
            (addi t0 t0 1)
          ])
        ];
      in
      regOf s a0;
    expected = 55;
  }
  {
    name = "dsl: call / ret and la + data";
    got =
      let
        s = run [
          (la a0 "msg")
          (call "load2")
          (j "done")
          (label "load2")
          (lbu a1 0 a0)
          (lbu a2 1 a0)
          ret
          (label "msg")
          (string "Hi")
          (align 4)
          (label "done")
        ];
      in
      map (regOf s) [
        a1
        a2
      ];
    expected = [
      72
      105
    ];
  }
  {
    name = "dsl: align pads to the boundary";
    got =
      let
        prog = assemble { base = 0; } [
          (string "abc")
          (align 4)
          (label "a")
          (string "d")
          (align 4)
          (label "b")
          (align 4)
          (label "c")
        ];
      in
      [
        prog.labels.a
        prog.labels.b
        prog.labels.c
        prog.size
      ];
    expected = [
      4
      8
      8
      8
    ];
  }
]
