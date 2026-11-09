# Minimal RV32IM assembler (instruction encoder) for tests.
# Immediates are taken as signed integers and scattered into each format's bit layout.
let
  B = import ./bits.nix;
  inherit (builtins) bitAnd;

  imm = x: len: bitAnd x (B.pow2 len - 1);
  field =
    x: lo: len:
    B.bits (imm x 32) lo len;

  r =
    funct7: funct3: opcode: rd: rs1: rs2:
    funct7 * 33554432 + rs2 * 1048576 + rs1 * 32768 + funct3 * 4096 + rd * 128 + opcode;

  i =
    funct3: opcode: rd: rs1: v:
    imm v 12 * 1048576 + rs1 * 32768 + funct3 * 4096 + rd * 128 + opcode;

  s =
    funct3: opcode: rs1: rs2: v:
    field v 5 7 * 33554432 + rs2 * 1048576 + rs1 * 32768 + funct3 * 4096 + field v 0 5 * 128 + opcode;

  b =
    funct3: rs1: rs2: v:
    field v 12 1 * 2147483648
    + field v 5 6 * 33554432
    + rs2 * 1048576
    + rs1 * 32768
    + funct3 * 4096
    + field v 1 4 * 256
    + field v 11 1 * 128
    + 99;

  u =
    opcode: rd: v:
    bitAnd (imm v 32) 4294963200 + rd * 128 + opcode;

  j =
    rd: v:
    field v 20 1 * 2147483648
    + field v 1 10 * 2097152
    + field v 11 1 * 1048576
    + field v 12 8 * 4096
    + rd * 128
    + 111;

  shiftI =
    funct7: funct3: rd: rs1: sh:
    r funct7 funct3 19 rd rs1 sh;
in
{
  lui = u 55;
  auipc = u 23;
  jal = j;
  jalr = i 0 103;

  beq = b 0;
  bne = b 1;
  blt = b 4;
  bge = b 5;
  bltu = b 6;
  bgeu = b 7;

  lb = i 0 3;
  lh = i 1 3;
  lw = i 2 3;
  lbu = i 4 3;
  lhu = i 5 3;

  sb = s 0 35;
  sh = s 1 35;
  sw = s 2 35;

  addi = i 0 19;
  slti = i 2 19;
  sltiu = i 3 19;
  xori = i 4 19;
  ori = i 6 19;
  andi = i 7 19;
  slli = shiftI 0 1;
  srli = shiftI 0 5;
  srai = shiftI 32 5;

  add = r 0 0 51;
  sub = r 32 0 51;
  sll = r 0 1 51;
  slt = r 0 2 51;
  sltu = r 0 3 51;
  xor = r 0 4 51;
  srl = r 0 5 51;
  sra = r 32 5 51;
  or = r 0 6 51;
  and = r 0 7 51;

  # M extension
  mul = r 1 0 51;
  mulh = r 1 1 51;
  mulhsu = r 1 2 51;
  mulhu = r 1 3 51;
  div = r 1 4 51;
  divu = r 1 5 51;
  rem = r 1 6 51;
  remu = r 1 7 51;

  # Doom extension (custom-0): fixed-point 16.16 multiply, `.insn r 0x0B, 0, 0, rd, rs1, rs2`.
  fixmul = r 0 0 11;

  fence = 15;
  ecall = 115;
  ebreak = 1048691;
}
