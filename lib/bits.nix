# 32-bit integer arithmetic helpers.
# Nix integers are 64-bit signed, so register values are always kept in
# unsigned form (0 .. 2^32-1) and truncated with mask32 after each operation.
let
  inherit (builtins)
    bitAnd
    bitOr
    bitXor
    div
    genList
    elemAt
    foldl'
    ;

  mask32 = 4294967295;
  sign32 = 2147483648;
  two32 = 4294967296;

  # Table of powers of two (shifts are emulated with multiplication and division).
  pow2List = genList (n: foldl' (a: _: a * 2) 1 (genList (x: x) n)) 63;
  pow2 = n: elemAt pow2List n;

  # Interpret an unsigned 32-bit value as a signed integer.
  toSigned = x: if x >= sign32 then x - two32 else x;

  # Normalize any integer to its unsigned 32-bit representation.
  u32 = x: bitAnd x mask32;

  add = a: b: bitAnd (a + b) mask32;
  sub = a: b: bitAnd (a - b) mask32;

  shl = x: n: bitAnd (x * pow2 n) mask32;
  srl = x: n: div x (pow2 n);

  # Arithmetic right shift. Nix `div` truncates toward zero, so negative values are corrected to floor.
  sra =
    x: n:
    let
      s = toSigned x;
      p = pow2 n;
    in
    u32 (if s >= 0 then div s p else -(div (-s + p - 1) p));

  # Bit-field extraction: x[lo + len - 1 : lo]
  bits =
    x: lo: len:
    bitAnd (div x (pow2 lo)) (pow2 len - 1);

  # Sign-extend a len-bit value and return it in unsigned 32-bit form.
  sext = x: len: if x >= pow2 (len - 1) then bitAnd (x - pow2 len) mask32 else x;

  lt = a: b: toSigned a < toSigned b;

  # --- M extension ---
  # A 32x32-bit product can reach 2^64, which overflows a signed 64-bit Nix integer.
  # The multiplier is therefore split into 16-bit halves so that every partial
  # product stays below 2^48.

  # Low 32 bits of the product (identical for signed and unsigned operands).
  mul =
    a: b:
    let
      bl = bitAnd b 65535;
      bh = div b 65536;
    in
    bitAnd (a * bl + bitAnd (a * bh) 65535 * 65536) mask32;

  # High 32 bits of the unsigned product: floor((a*bh*2^16 + a*bl) / 2^32).
  mulhu =
    a: b:
    let
      bl = bitAnd b 65535;
      bh = div b 65536;
    in
    div (a * bh + div (a * bl) 65536) 65536;

  # Signed high words are derived from the unsigned one: interpreting an operand
  # as signed subtracts 2^32 times the other operand when its sign bit is set.
  mulh = a: b: u32 (mulhu a b - (if a >= sign32 then b else 0) - (if b >= sign32 then a else 0));

  # rs1 signed, rs2 unsigned.
  mulhsu = a: b: u32 (mulhu a b - (if a >= sign32 then b else 0));

  # Division follows the RISC-V rules: division by zero yields all ones for the
  # quotient and the dividend for the remainder. Nix `div` truncates toward zero
  # as required, and INT_MIN / -1 evaluates to 2^31 in 64 bits, which u32 maps
  # back to INT_MIN (with remainder 0), so signed overflow needs no special case.
  divu = a: b: if b == 0 then mask32 else div a b;
  remu = a: b: if b == 0 then a else a - div a b * b;
  divs = a: b: if b == 0 then mask32 else u32 (div (toSigned a) (toSigned b));
  rems =
    a: b:
    let
      sa = toSigned a;
      sb = toSigned b;
    in
    if b == 0 then a else u32 (sa - div sa sb * sb);
in
{
  inherit
    mask32
    sign32
    two32
    pow2
    toSigned
    u32
    add
    sub
    shl
    srl
    sra
    bits
    sext
    lt
    mul
    mulhu
    mulh
    mulhsu
    divu
    remu
    divs
    rems
    bitAnd
    bitOr
    bitXor
    ;
}
