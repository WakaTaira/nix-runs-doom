# Spike variant `rv` (option 1): the reference C of the spike compiled by
# `clang --target=riscv32 -march=rv32im -O2` and copied into the eDSL one
# instruction at a time, with clang's labels, register allocation, call structure
# and inlining decisions. Nothing is hand-optimized. clang inlines all three
# helpers into `unit`; the standalone FixedMul, R_DrawColumn and R_DrawSpan are
# kept as clang emitted them although nothing calls them.
#
# With `useFixmul = true` (variant `rvx`, see rvx.nix) the instruction sequences
# clang emitted for FixedMul's 64-bit multiply and shift are replaced by the
# single custom instruction `fixmul`. Nothing else differs.
#
# Layout: the program (code only) is placed at address 0, below the data image of
# data.nix (0x00100000..). The stack starts at 0x00200000, above the last data word
# (RESULT at 0x00123000); `unit` uses 32 bytes of it.
{
  useFixmul ? false,
}:
let
  C = import ../../lib/cpu.nix;
  D = import ../../lib/dsl.nix;
  Data = import ./data.nix;

  codeBase = 0;
  stackTop = 2097152;
  maxSteps = 10000000;

  # The clang sequence for the 64-bit multiply and shift, or its fixmul replacement.
  mulShift = plain: custom: if useFixmul then custom else plain;
in
with D;
let
  start = [
    (label "_start")
    (li sp stackTop)
    (li a0 Data.PARAMS)
    (call "unit")
    (li a0 0)
    (li a7 93)
    ecall
  ];

  fixedMul = [
    (label "FixedMul")
    (mulShift [
      (mul a2 a1 a0)
      (mulh a0 a1 a0)
      (slli a0 a0 16)
      (srli a2 a2 16)
      (D.or a0 a2 a0)
    ] (fixmul a0 a1 a0))
    ret
  ];

  drawColumn = [
    (label "R_DrawColumn")
    (slli a6 a5 6)
    (slli a5 a5 8)
    (add a5 a5 a6)
    (add a5 a0 a5)
    (label ".LBB1_1")
    (slli a6 a3 9)
    (srli a6 a6 25)
    (add a6 a1 a6)
    (lbu a6 0 a6)
    (add a6 a2 a6)
    (lbu a6 0 a6)
    (sb a6 0 a0)
    (addi a0 a0 320)
    (add a3 a3 a4)
    (bne a0 a5 ".LBB1_1")
    ret
  ];

  drawSpan = [
    (label "R_DrawSpan")
    (add a7 a0 a7)
    (lui t0 (1 * 4096))
    (addi t0 t0 (-64))
    (label ".LBB2_1")
    (srli t1 a4 10)
    (slli t2 a3 10)
    (and t1 t1 t0)
    (srli t2 t2 26)
    (add t1 a1 t1)
    (add t1 t1 t2)
    (lbu t1 0 t1)
    (add t1 a2 t1)
    (lbu t1 0 t1)
    (addi t2 a0 1)
    (add a3 a3 a5)
    (sb t1 0 a0)
    (add a4 a4 a6)
    (mv a0 t2)
    (bne t2 a7 ".LBB2_1")
    ret
  ];

  unit = [
    (label "unit")
    (lw a1 0 a0)
    (bge zero a1 ".LBB3_18") # blez a1
    (addi sp sp (-32))
    (sw s0 28 sp)
    (sw s1 24 sp)
    (sw s2 20 sp)
    (sw s3 16 sp)
    (sw s4 12 sp)
    (sw s5 8 sp)
    (sw s6 4 sp)
    (li a1 0)
    (lui a2 (288 * 4096))
    (lui a3 (272 * 4096))
    (lui a4 (289 * 4096))
    (lui a5 (8 * 4096))
    (lui t3 (1 * 4096))
    (lui a6 (290 * 4096))
    (lui a7 (16 * 4096))
    (lui t4 (18 * 4096))
    (lui t5 (2 * 4096))
    (addi t0 a2 (-1536))
    (addi t1 a3 320)
    (addi t2 a3 160)
    (addi t3 t3 (-64))
    (addi t4 t4 837)
    (addi t5 t5 (-273))
    (lui t6 (291 * 4096))
    (j ".LBB3_4")
    (label ".LBB3_2")
    (li s1 0)
    (label ".LBB3_3")
    (lw s0 0 t6)
    (add s0 s0 s1)
    (sw s0 0 t6)
    (lw s0 0 a0)
    (addi a1 a1 1)
    (bge a1 s0 ".LBB3_17")
    (label ".LBB3_4")
    (lw s0 4 a0)
    (bge zero s0 ".LBB3_9") # blez s0
    (li s0 0)
    (label ".LBB3_6")
    (add s1 s0 t0)
    (add s2 s0 a3)
    (slli s3 s0 12)
    (label ".LBB3_7")
    (slli s4 s3 9)
    (srli s4 s4 25)
    (D.or s4 s4 a4)
    (lbu s4 0 s4)
    (D.or s4 s4 a2)
    (lbu s4 0 s4)
    (sb s4 0 s2)
    (addi s2 s2 320)
    (add s3 s3 a5)
    (bne s2 s1 ".LBB3_7")
    (lw s1 4 a0)
    (addi s0 s0 1)
    (blt s0 s1 ".LBB3_6")
    (label ".LBB3_9")
    (lw s0 8 a0)
    (bge zero s0 ".LBB3_14") # blez s0
    (li s0 0)
    (label ".LBB3_11")
    (slli s2 s0 6)
    (slli s3 s0 8)
    (slli s1 s0 14)
    (add s3 s3 s2)
    (add s2 s3 t1)
    (add s4 s3 t2)
    (slli s3 s0 16)
    (label ".LBB3_12")
    (srli s5 s3 10)
    (slli s6 s1 10)
    (and s5 s5 t3)
    (srli s6 s6 26)
    (D.or s5 s5 s6)
    (D.or s5 s5 a6)
    (lbu s5 0 s5)
    (D.or s5 s5 a2)
    (lbu s5 0 s5)
    (addi s6 s4 1)
    (add s1 s1 a7)
    (sb s5 0 s4)
    (addi s3 s3 1024)
    (mv s4 s6)
    (bne s6 s2 ".LBB3_12")
    (lw s1 8 a0)
    (addi s0 s0 1)
    (blt s0 s1 ".LBB3_11")
    (label ".LBB3_14")
    (lw s0 12 a0)
    (bge zero s0 ".LBB3_2") # blez s0
    (li s2 0)
    (li s1 0)
    (mv s3 t4)
    (label ".LBB3_16")
    # Inlined FixedMul: the multiply and shift are interleaved with the loop updates.
    (mulShift [
      (mul s4 s3 s2)
      (mulhu s5 s3 s2)
    ] (fixmul s4 s3 s2))
    (addi s0 s0 (-1))
    (addi s3 s3 1)
    (mulShift
      [
        (slli s5 s5 16)
        (srli s4 s4 16)
        (D.or s4 s4 s5)
      ]
      [ ]
    )
    (add s1 s1 s4)
    (add s2 s2 t5)
    (bnez s0 ".LBB3_16")
    (j ".LBB3_3")
    (label ".LBB3_17")
    (lw s0 28 sp)
    (lw s1 24 sp)
    (lw s2 20 sp)
    (lw s3 16 sp)
    (lw s4 12 sp)
    (lw s5 8 sp)
    (lw s6 4 sp)
    (addi sp sp 32)
    (label ".LBB3_18")
    ret
  ];

  program = assemble { base = codeBase; } [
    start
    fixedMul
    drawColumn
    drawSpan
    unit
  ];

  # Place the program over a data image and run it from _start to exit.
  # The code region covers the program only, not the data.
  runState =
    mem:
    C.run { inherit maxSteps; } (
      C.mkState {
        mem = toMemory mem program;
        pc = program.entry;
        code = {
          base = program.base;
          inherit (program) size;
        };
      }
    );

  run =
    mem:
    let
      s = runState mem;
    in
    if s.exitCode == 0 then
      s.mem
    else
      throw "spike rv: exit code ${toString s.exitCode} after ${toString s.count} instructions";
in
{
  inherit program runState run;
}
