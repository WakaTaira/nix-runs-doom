# FizzBuzz written in the Nix eDSL (lib/dsl.nix) and assembled straight into
# RV32I machine code by Nix: no C compiler, no ELF, no hex fixture.
#
# Same algorithm as the C reference in examples/fizzbuzz-c: RV32I has no
# multiply/divide, so it keeps period counters for 3 and 5 and an array of
# decimal digits (least significant first) that it increments in place.
#
# Register plan:
#   s0 = i           s1 = i mod 3      s2 = i mod 5     s3 = line length
#   s4 = ndigits     s5 = &digits      s6 = &line       s7 = N + 1
#   s8 = 3           s9 = 5
{
  n ? 100,
}:
let
  D = import ../../lib/dsl.nix;
in
with D;
let
  # line[s3++] = byte in register r (macro: expands to three instructions)
  appendReg = r: [
    (add t1 s6 s3)
    (sb r 0 t1)
    (addi s3 s3 1)
  ];

  # Append a constant string, one byte at a time. The loop over characters
  # runs in Nix at assembly time, so it unrolls into straight-line code.
  appendString =
    str:
    map (b: [
      (li t0 b)
      (appendReg t0)
    ]) (builtins.genList (i: ord (builtins.substring i 1 str)) (builtins.stringLength str));

  syscall = nr: [
    (li a7 nr)
    ecall
  ];

  main = [
    (la s5 "digits")
    (la s6 "line")
    (li s0 1)
    (li s1 0)
    (li s2 0)
    (li s4 1)
    (li s7 (n + 1))
    (li s8 3)
    (li s9 5)

    (while (ne s0 s7) [
      (call "incrementDigits")

      (addi s1 s1 1)
      (when (eq s1 s8) [ (mv s1 zero) ])
      (addi s2 s2 1)
      (when (eq s2 s9) [ (mv s2 zero) ])

      (li s3 0)
      (when (eq s1 zero) (appendString "Fizz"))
      (when (eq s2 zero) (appendString "Buzz"))
      (when (eq s3 zero) [
        # Copy digits most significant first.
        (addi t2 s4 (-1))
        (while (ge t2 zero) [
          (add t3 s5 t2)
          (lbu t4 0 t3)
          (appendReg t4)
          (addi t2 t2 (-1))
        ])
      ])
      (appendString "\n")

      # write(1, line, length)
      (li a0 1)
      (mv a1 s6)
      (mv a2 s3)
      (syscall 64)

      (addi s0 s0 1)
    ])

    # exit(0)
    (li a0 0)
    (syscall 93)
  ];

  # Increment the decimal counter in `digits`, growing it on carry-out.
  incrementDigits = [
    (label "incrementDigits")
    (li t0 0) # k
    (li t5 (ord "9"))
    (label "incrementDigits.loop")
    (when (eq t0 s4) [
      (add t1 s5 t0)
      (li t2 (ord "1"))
      (sb t2 0 t1)
      (addi s4 s4 1)
      ret
    ])
    (add t1 s5 t0)
    (lbu t2 0 t1)
    (when (eq t2 t5) [
      (li t2 (ord "0"))
      (sb t2 0 t1)
      (addi t0 t0 1)
      (j "incrementDigits.loop")
    ])
    (addi t2 t2 1)
    (sb t2 0 t1)
    ret
  ];

  dataSection = [
    (label "digits")
    (string "0000")
    (align 4)
    (label "line")
    (space 16)
  ];
in
assemble { } [
  main
  incrementDigits
  dataSection
]
